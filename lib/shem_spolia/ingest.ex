defmodule ShemSpolia.Ingest do
  @moduledoc """
  Turns a JSON object on stdin into a chained event.

  This is the only path by which activity the auditor did not itself perform
  enters the log. It exists because an MCP server structurally cannot see a
  client's calls to *other* servers, let alone its built-in tools — so the
  client has to hand us the record. Claude Code's `PostToolUse` hook does
  exactly that, for every tool including `Bash` and `Edit`.

  ## What this proves, and what it does not

  The chain proves nobody edited the record after the fact. It says nothing
  about what never entered it: the hook runs because a config file says so,
  and that config is editable by whoever runs the agent. This is a
  tamper-evident record of what was recorded, not proof of everything that
  happened. Every cooperative audit log has this property; naming it is the
  difference between evidence and a claim.

  ## Shapes accepted

  A Claude Code hook payload is recognized by `tool_name` / `hook_event_name`
  and mapped onto the event vocabulary `Attest` already understands. Anything
  else is recorded verbatim under `--type`, which defaults to `:external`.
  """

  alias ShemSpolia.EventLog

  # tool_response on a Read of a large file is megabytes, and the chain is not
  # a place to store file contents. Oversized strings collapse to their own
  # SHA-256 plus a head, so the record still commits to the exact bytes it saw
  # without carrying them.
  @default_max_bytes 8_192
  @head_bytes 256

  @session_id_re ~r/^[A-Za-z0-9_.\-]{1,96}$/

  @type opts :: [session: String.t() | nil, type: String.t() | nil, max_bytes: pos_integer()]

  @doc """
  Parse one JSON object, derive session/type/payload, append to the chain.

  Returns `{:ok, session_id, event_id}` or `{:error, reason}`.
  """
  @spec ingest(binary(), opts()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def ingest(raw, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with {:ok, obj} <- decode(raw),
         {:ok, session_id} <- session_id(obj, Keyword.get(opts, :session)),
         {type, payload} <- classify(obj, Keyword.get(opts, :type)) do
      payload = cap(payload, max_bytes)

      {:ok, ^session_id} = EventLog.start_session(session_id)

      case EventLog.append(session_id, type, payload) do
        {:ok, event} -> {:ok, session_id, event.id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode(raw) do
    case Jason.decode(String.trim(raw)) do
      {:ok, %{} = obj} -> {:ok, obj}
      {:ok, _} -> {:error, :not_an_object}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  # ── session ────────────────────────────────────────────────────────────────

  # An explicit --session wins. Otherwise a client's own session id (a UUID,
  # in Claude Code's case) is folded into spolia's id shape: deterministic, so
  # every tool call in one agent session lands in one chain, and constrained,
  # so nothing a client sends can escape the log directory as a path.
  defp session_id(obj, nil) do
    case obj["session_id"] do
      id when is_binary(id) and id != "" -> {:ok, derive(id)}
      _ -> {:error, :no_session}
    end
  end

  defp session_id(_obj, explicit) do
    if Regex.match?(@session_id_re, explicit) do
      {:ok, explicit}
    else
      {:error, {:bad_session_id, explicit}}
    end
  end

  @doc "Deterministic spolia session id for a foreign session identifier."
  @spec derive(String.t()) :: String.t()
  def derive(external) do
    hex =
      :crypto.hash(:sha256, external)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "ses_" <> hex
  end

  # ── classification ─────────────────────────────────────────────────────────

  # `:agent_tool_called` with a `tool` key is the vocabulary Attest.collect_tools/1
  # already filters on, so hook-recorded calls appear in bundles as tools without
  # any change there.
  defp classify(%{"tool_name" => name} = obj, nil) when is_binary(name) do
    {:agent_tool_called,
     %{
       tool: name,
       arguments: obj["tool_input"] || %{},
       result: obj["tool_response"],
       source: source_of(obj)
     }}
  end

  defp classify(%{"hook_event_name" => hook} = obj, nil) when is_binary(hook) do
    {:agent_hook,
     %{
       hook: hook,
       payload: Map.drop(obj, ["session_id", "transcript_path"]),
       source: source_of(obj)
     }}
  end

  defp classify(obj, nil), do: {:external, obj}

  defp classify(obj, type) when is_binary(type) do
    case classify(obj, nil) do
      # an explicit --type overrides the mapping but keeps the mapped payload
      {_mapped, payload} -> {safe_type(type), payload}
    end
  end

  # Event types are atoms and this input is untrusted, so the atom table is not
  # something the caller gets to grow. Unknown types record as :external.
  defp safe_type("agent_tool_called"), do: :agent_tool_called
  defp safe_type("agent_hook"), do: :agent_hook
  defp safe_type("agent_message"), do: :agent_message
  defp safe_type("agent_turn"), do: :agent_turn
  defp safe_type("tool_invoked"), do: :tool_invoked
  defp safe_type(_), do: :external

  defp source_of(obj) do
    %{
      client: obj["hook_event_name"] || "external",
      external_session_id: obj["session_id"],
      cwd: obj["cwd"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # ── size cap ───────────────────────────────────────────────────────────────

  defp cap(term, max), do: walk(term, max)

  defp walk(s, max) when is_binary(s) do
    if byte_size(s) > max do
      %{
        "$truncated" => %{
          "sha256" => :crypto.hash(:sha256, s) |> Base.encode16(case: :lower),
          "bytes" => byte_size(s),
          "head" => String.slice(s, 0, @head_bytes)
        }
      }
    else
      s
    end
  end

  defp walk(%{} = m, max), do: Map.new(m, fn {k, v} -> {k, walk(v, max)} end)
  defp walk(l, max) when is_list(l), do: Enum.map(l, &walk(&1, max))
  defp walk(other, _max), do: other
end
