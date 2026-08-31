defmodule ShemSpolia.Needle do
  @moduledoc """
  Transport for [Cactus Needle](https://cactuscompute.com/needle) — a 45M
  parameter tool-calling model shipped as a single self-contained binary.

  Needle is not a chat model and this is not a chat transport. It answers one
  question: given these tool schemas and this sentence, which call, with which
  arguments? Off-topic input returns the empty call `[]` rather than prose.

  ## Two modes, and why both exist

  `complete/2` spawns `needle --prompt` per turn: stateless, isolated, no
  process to supervise, ~350 ms cold. Correct when each turn stands alone.

  `ShemSpolia.Needle.Session` holds a `needle --serve` process and speaks HTTP
  to it. Needle's server keeps conversation state — feed a tool result back as
  the next input and it continues from there, and a later bare query resolves
  against earlier turns. **That state is per-process**, so a session owns its
  server exclusively; sharing one across concurrent conversations would let
  them read each other's history.

  ## What gets recorded

  `audited_complete/3` wraps either mode and appends `:llm_call_started` and
  `:llm_call_completed` to the session's hash chain, so a Needle turn is
  evidence in exactly the way an Anthropic or OpenAI turn would be. Needle
  reports two things worth chaining that a cloud model does not:

    * `confidence` — a calibrated score. The documented contract is to act at
      or above a threshold and escalate below it, so the number belongs in the
      record: it is why the agent proceeded.
    * `validation` — the model's own grounding check (`ungrounded` argument
      names, `negation` detected). Present on tool calls, absent on refusals.

  ## Binary discovery

  `NEEDLE_PATH`, then app config `:needle_path`, then `needle` on PATH.
  """

  alias ShemSpolia.Needle.Response

  @default_timeout 30_000

  @doc "Absolute path to the needle binary, or nil if it cannot be found."
  @spec binary_path() :: String.t() | nil
  def binary_path do
    configured =
      System.get_env("NEEDLE_PATH") || Application.get_env(:shem_spolia, :needle_path)

    cond do
      is_binary(configured) and File.exists?(configured) -> Path.expand(configured)
      is_binary(configured) -> nil
      true -> System.find_executable("needle")
    end
  end

  @doc "Whether a usable needle binary is present."
  @spec available?() :: boolean()
  def available?, do: binary_path() != nil

  @doc """
  One-shot completion. Spawns `needle --prompt`, reads one JSON object, exits.

  Options:

    * `:tools` — list of tool schema maps (Needle's `tools.json` shape). Also
      accepts a path to an existing JSON file.
    * `:system` — session facts string, e.g. `"date: 2026-08-31; device: laptop"`.
      Facts only; Needle ignores instructions placed here.
    * `:max` — response token limit (Needle's default is 256).
    * `:timeout` — milliseconds to wait. Default #{@default_timeout}.
  """
  @spec complete(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def complete(query, opts \\ []) when is_binary(query) do
    case binary_path() do
      nil ->
        {:error, :needle_not_found}

      bin ->
        with {:ok, tools_path, cleanup} <- tools_file(opts[:tools]),
             {:ok, sys_path, sys_cleanup} <- system_file(opts[:system]) do
          args =
            ["--prompt", query]
            |> prepend_if(tools_path, ["--tools", tools_path])
            |> prepend_if(sys_path, ["--system", sys_path])
            |> prepend_if(opts[:max], ["--max", to_string(opts[:max])])

          result = run(bin, args, opts[:timeout] || @default_timeout)
          cleanup.()
          sys_cleanup.()
          result
        end
    end
  end

  defp prepend_if(args, nil, _extra), do: args
  defp prepend_if(args, _present, extra), do: extra ++ args

  # Port over System.cmd: a Port is killable, gives us the exit status, and is
  # the same mechanism the rest of the system uses for external processes.
  defp run(bin, args, timeout) do
    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :hide,
        args: args
      ])

    collect(port, "", timeout)
  end

  defp collect(port, acc, timeout) do
    receive do
      {^port, {:data, chunk}} ->
        collect(port, acc <> chunk, timeout)

      {^port, {:exit_status, 0}} ->
        Response.parse(acc)

      {^port, {:exit_status, code}} ->
        {:error, {:needle_exit, code, String.trim(acc)}}
    after
      timeout ->
        safe_close(port)
        {:error, :timeout}
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port), do: Port.close(port)
  catch
    _, _ -> :ok
  end

  @doc """
  Run a Needle turn and record it in `session_id`'s hash chain.

  Appends `:llm_call_started` before and `:llm_call_completed` after (or
  `:llm_call_failed` if the model could not be reached). Returns whatever the
  underlying call returned — logging never changes the result, and a logging
  failure never fails the call.

  `target` is either `:oneshot` (default) or a `ShemSpolia.Needle.Session` pid,
  so the same recording path covers both modes.
  """
  @spec audited_complete(String.t(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def audited_complete(session_id, query, opts \\ []) do
    {target, opts} = Keyword.pop(opts, :target, :oneshot)

    ShemSpolia.EventLog.append(session_id, :llm_call_started, %{
      model: "needle",
      transport: transport_tag(target),
      query: query,
      tools: tool_names(opts[:tools])
    })

    result =
      case target do
        :oneshot -> complete(query, opts)
        pid when is_pid(pid) -> ShemSpolia.Needle.Session.complete(pid, query, opts)
      end

    case result do
      {:ok, %Response{} = r} ->
        ShemSpolia.EventLog.append(session_id, :llm_call_completed, %{
          model: "needle",
          type: r.type,
          tool_calls: r.tool_calls,
          reasoning: r.reasoning,
          confidence: r.confidence,
          validation: r.validation,
          decode_tps: r.decode_tps,
          peak_ram_mb: r.peak_ram_mb
        })

      {:error, reason} ->
        ShemSpolia.EventLog.append(session_id, :llm_call_failed, %{
          model: "needle",
          error: inspect(reason)
        })
    end

    result
  end

  defp transport_tag(:oneshot), do: "oneshot"
  defp transport_tag(pid) when is_pid(pid), do: "serve"

  defp tool_names(nil), do: []
  defp tool_names(path) when is_binary(path), do: [%{source: path}]

  defp tool_names(tools) when is_list(tools),
    do: Enum.map(tools, fn t -> t[:name] || t["name"] end)

  # ── tool / system file plumbing ────────────────────────────────────────────

  @doc false
  def tools_file(nil), do: {:ok, nil, fn -> :ok end}

  def tools_file(path) when is_binary(path) do
    if File.exists?(path), do: {:ok, path, fn -> :ok end}, else: {:error, {:tools_not_found, path}}
  end

  def tools_file(tools) when is_list(tools) do
    path =
      Path.join(
        System.tmp_dir!(),
        "needle_tools_#{:erlang.unique_integer([:positive])}.json"
      )

    File.write!(path, encode_tools(tools))
    {:ok, path, fn -> File.rm(path) end}
  end

  @doc """
  Serialize tool schemas with `name` first in every tool object.

  This is not cosmetic. Needle's prompt is assembled from the schema in file
  order, and a tool whose object does not lead with `name` can become
  invisible to the model — it answers `[]` ("no tool available") with high
  confidence, which is indistinguishable from a legitimate refusal.

  Measured on needle2 linux-x86_64, 16 permutations, deterministic: all 8 with
  `name` first produced the call; all 4 with `description` first AND an
  apostrophe in the description refused. Nested key order never mattered.
  Since Elixir maps do not preserve insertion order (`Jason.encode!` on a map
  emits whatever order the map iterates), emitting the JSON by hand is the
  only way to guarantee this.
  """
  @spec encode_tools([map()]) :: binary()
  def encode_tools(tools) when is_list(tools) do
    "[" <> Enum.map_join(tools, ",", &encode_tool/1) <> "]"
  end

  defp encode_tool(tool) when is_map(tool) do
    name = tool[:name] || tool["name"]
    rest = tool |> normalize_keys() |> Map.delete("name")

    pairs =
      [~s("name":#{Jason.encode!(name)})] ++
        Enum.map(rest, fn {k, v} -> "#{Jason.encode!(k)}:#{Jason.encode!(v)}" end)

    "{" <> Enum.join(pairs, ",") <> "}"
  end

  defp normalize_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  @doc false
  def system_file(nil), do: {:ok, nil, fn -> :ok end}

  def system_file(facts) when is_binary(facts) do
    path =
      Path.join(System.tmp_dir!(), "needle_system_#{:erlang.unique_integer([:positive])}.txt")

    File.write!(path, facts)
    {:ok, path, fn -> File.rm(path) end}
  end
end