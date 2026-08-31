defmodule ShemSpolia.Needle.Session do
  @moduledoc """
  A supervised `needle --serve` process plus the HTTP conversation with it.

  Needle's server holds conversation state: feed a tool result back as the next
  input and the model continues from it, and a later bare query ("now the
  bedroom too") resolves against earlier turns. **That state lives in the OS
  process**, so one server belongs to exactly one conversation. Two callers
  sharing a session would see each other's history; start a session per
  conversation instead.

  The port binding is `127.0.0.1` — Needle's own default — so a session is not
  reachable off-box.

  Uses a small `:gen_tcp` HTTP client (`ShemSpolia.Needle.HTTP`) rather than
  `:httpc`: the whole point of the escript is that it drops onto a machine with
  nothing installed, and `:httpc` builds TLS defaults before it inspects the
  scheme, so it needs `:ssl` and `:public_key` even for a plain loopback POST.
  """

  use GenServer

  alias ShemSpolia.Needle
  alias ShemSpolia.Needle.Response

  @startup_timeout 15_000
  @request_timeout 60_000

  # ── client ─────────────────────────────────────────────────────────────────

  @doc """
  Start a Needle server and connect to it.

  Options:

    * `:tools` — tool schemas (list) or a path to a tools JSON file
    * `:system` — session facts string
    * `:tool_index` — path for persisted tool embeddings; worth setting when
      the catalogue is large, since it survives restarts
    * `:port` — TCP port. Defaults to an OS-assigned free port.
    * `:name` — GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Send a turn. The server remembers it."
  @spec complete(GenServer.server(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def complete(server, input, opts \\ []) do
    GenServer.call(server, {:complete, input}, opts[:timeout] || @request_timeout)
  end

  @doc "Rewind the conversation, keeping the tools loaded."
  @spec reset(GenServer.server()) :: :ok | {:error, term()}
  def reset(server), do: GenServer.call(server, :reset, @request_timeout)

  @doc "The port this session's server is listening on."
  @spec port(GenServer.server()) :: pos_integer()
  def port(server), do: GenServer.call(server, :port)

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, bin} <- find_binary(),
         {:ok, tcp_port} <- resolve_port(opts[:port]),
         {:ok, tools_path, cleanup} <- Needle.tools_file(opts[:tools]),
         {:ok, sys_path, sys_cleanup} <- Needle.system_file(opts[:system]) do
      args =
        ["--serve", "--port", to_string(tcp_port)]
        |> maybe_arg(tools_path, ["--tools", tools_path])
        |> maybe_arg(sys_path, ["--system", sys_path])
        |> maybe_arg(opts[:tool_index], ["--tool-index", to_string(opts[:tool_index])])

      port =
        Port.open({:spawn_executable, bin}, [
          :binary,
          :exit_status,
          :hide,
          # stderr_to_stdout keeps needle's banner and any error text on the
          # port we own, rather than letting it inherit (and hold open) the
          # VM's own stdout — which is what made a finished test suite hang
          # behind a leaked child.
          :stderr_to_stdout,
          args: args
        ])

      state = %{
        port: port,
        tcp_port: tcp_port,
        cleanup: fn ->
          cleanup.()
          sys_cleanup.()
        end
      }

      case wait_until_listening(tcp_port, @startup_timeout) do
        :ok ->
          {:ok, state}

        {:error, reason} ->
          state.cleanup.()
          {:stop, {:needle_did_not_start, reason}}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp maybe_arg(args, nil, _extra), do: args
  defp maybe_arg(args, _present, extra), do: args ++ extra

  defp find_binary do
    case Needle.binary_path() do
      nil -> {:error, :needle_not_found}
      bin -> {:ok, bin}
    end
  end

  # Ask the OS for a free port, then hand the number to needle. There is a
  # race between closing and needle binding, but it is small and the
  # alternative — a fixed port — collides between concurrent sessions, which
  # is the failure this exists to avoid.
  defp resolve_port(nil) do
    case :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        {:ok, assigned} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, assigned}

      {:error, reason} ->
        {:error, {:no_free_port, reason}}
    end
  end

  defp resolve_port(port) when is_integer(port), do: {:ok, port}

  defp wait_until_listening(_tcp_port, remaining) when remaining <= 0, do: {:error, :timeout}

  defp wait_until_listening(tcp_port, remaining) do
    case :gen_tcp.connect(~c"127.0.0.1", tcp_port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        Process.sleep(100)
        wait_until_listening(tcp_port, remaining - 350)
    end
  end

  @impl true
  def handle_call({:complete, input}, _from, state) do
    {:reply, post(state.tcp_port, "/complete", %{"input" => input}), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    reply =
      case post_raw(state.tcp_port, "/reset", "{}") do
        {:ok, _} -> :ok
        error -> error
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.tcp_port, state}

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    {:stop, {:needle_exited, code}, state}
  end

  # needle logs its banner to stdout; not interesting, and it must not become
  # a mailbox leak.
  @impl true
  def handle_info({port, {:data, _}}, %{port: port} = state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.cleanup.()
    kill_server(state)
    :ok
  catch
    _, _ -> :ok
  end

  # Closing the Port is NOT enough. `Port.close/1` detaches the BEAM from the
  # pipe but leaves the OS process alive — a leaked `needle --serve` keeps its
  # TCP port and ~26 MB of RAM forever, and because it inherits our stdout it
  # also holds that pipe open, so anything reading our output never sees EOF.
  # (Observed: 8 orphans after one test run, and a `| tail` that hung on a
  # finished suite.)
  #
  # So: ask the OS process directly. `:os_pid` comes from Port.info/1; SIGTERM
  # first, then SIGKILL for anything that ignores it.
  defp kill_server(%{port: port}) do
    info = is_port(port) && Port.info(port)
    os_pid = info && info[:os_pid]

    if os_pid do
      System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
      # Needle exits promptly on TERM; this is the backstop, not the plan.
      Process.sleep(50)
      System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    end

    if is_port(port) and Port.info(port), do: Port.close(port)
  end

  # ── http ───────────────────────────────────────────────────────────────────

  defp post(tcp_port, path, body) do
    case post_raw(tcp_port, path, Jason.encode!(body)) do
      {:ok, response_body} -> Response.parse(response_body)
      error -> error
    end
  end

  defp post_raw(tcp_port, path, body) do
    ShemSpolia.Needle.HTTP.post(tcp_port, path, body, @request_timeout)
  end
end