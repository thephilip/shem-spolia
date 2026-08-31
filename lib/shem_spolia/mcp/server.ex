defmodule ShemSpolia.MCP.Server do
  @moduledoc """
  MCP server over stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout.

  Deliberately minimal — `initialize`, `tools/list`, `tools/call`, plus ping
  and the notification no-ops. Every tool call is itself recorded into the
  `ses_TOOL_INVOCATIONS` chain, so the auditor's own activity is auditable.

  stdout is the wire: nothing else may print there. Diagnostics go to stderr.
  """

  alias ShemSpolia.MCP.Router

  @protocol_version "2025-06-18"
  @invocation_session "ses_TOOL_INVOCATIONS"

  @spec serve() :: :ok
  def serve do
    {:ok, _} = ShemSpolia.EventLog.start_session(@invocation_session)
    loop()
  end

  defp loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "stdin error: #{inspect(reason)}")
        :ok

      line ->
        line |> String.trim() |> handle_line()
        loop()
    end
  end

  defp handle_line(""), do: :ok

  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, %{"method" => method} = req} ->
        id = Map.get(req, "id")
        params = Map.get(req, "params") || %{}

        case handle(method, params) do
          :notification -> :ok
          {:ok, result} -> respond(id, result)
          {:error, code, message} -> respond_error(id, code, message)
        end

      {:ok, _} ->
        respond_error(nil, -32600, "invalid request")

      {:error, _} ->
        respond_error(nil, -32700, "parse error")
    end
  end

  # ── methods ────────────────────────────────────────────────────────────────

  defp handle("initialize", _params) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{
         "name" => "shem-spolia",
         "version" => to_string(Application.spec(:shem_spolia, :vsn))
       }
     }}
  end

  defp handle("tools/list", _params), do: {:ok, %{"tools" => Router.manifest()}}

  defp handle("tools/call", params) do
    name = Map.get(params, "name")
    args = Map.get(params, "arguments") || %{}

    started = System.monotonic_time(:millisecond)
    result = Router.dispatch(name, args)
    took = System.monotonic_time(:millisecond) - started

    record(name, args, result, took)

    case result do
      {:ok, payload} ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
           "isError" => false
         }}

      {:error, message} ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => message}],
           "isError" => true
         }}
    end
  end

  defp handle("ping", _params), do: {:ok, %{}}

  defp handle("notifications/" <> _, _params), do: :notification

  defp handle(method, _params), do: {:error, -32601, "method not found: #{method}"}

  # ── the auditor audits itself ──────────────────────────────────────────────

  defp record(name, args, result, took_ms) do
    status =
      case result do
        {:ok, _} -> "ok"
        {:error, _} -> "error"
      end

    ShemSpolia.EventLog.append(@invocation_session, :tool_invoked, %{
      tool: name,
      arguments: args,
      status: status,
      took_ms: took_ms
    })
  rescue
    # never let the audit trail take down the call it is recording
    e -> IO.puts(:stderr, "invocation log failed: #{Exception.message(e)}")
  end

  # ── wire ───────────────────────────────────────────────────────────────────

  defp respond(nil, _result), do: :ok

  defp respond(id, result) do
    emit(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp respond_error(nil, _code, _message), do: :ok

  defp respond_error(id, code, message) do
    emit(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
  end

  defp emit(map) do
    IO.puts(Jason.encode!(map))
  end
end