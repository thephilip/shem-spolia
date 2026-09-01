defmodule ShemSpolia.Web.Stream do
  @moduledoc """
  Server-sent events: a live tail of the auditor's own state.

  The EventLog is a plain GenServer with no pub/sub, and adding a broadcast to
  the append path would mean the recording hot path carries the cost of a
  feature only the demo surface uses. So this polls instead — cheap, honest,
  and it also catches changes made by a *different* process (a second
  `shem_audit` writing the same log directory), which a broadcast would miss.

  The poll key is `{session_id, event_count, head_hash}` per session. Comparing
  head hashes rather than counts alone means a rewritten history of the same
  length still registers as a change — which is exactly the event this tool
  exists to notice.
  """

  require Logger

  alias ShemSpolia.Web.API

  @poll_ms 1_000
  # Long enough that an idle tab doesn't spin, short enough that proxies and
  # impatient browsers don't decide the connection died.
  @keepalive_ms 15_000

  @spec run(:gen_tcp.socket(), map()) :: :ok
  def run(socket, _query) do
    headers = [
      "HTTP/1.1 200 OK\r\n",
      "Content-Type: text/event-stream\r\n",
      "Cache-Control: no-store\r\n",
      "Connection: close\r\n",
      # Without this, any buffering layer will hold frames until the response
      # ends — which for an infinite stream is never.
      "X-Accel-Buffering: no\r\n\r\n"
    ]

    case :gen_tcp.send(socket, headers) do
      :ok -> loop(socket, snapshot(), System.monotonic_time(:millisecond), true)
      {:error, _} -> :ok
    end
  after
    :gen_tcp.close(socket)
  end

  defp loop(socket, previous, last_write, force) do
    now = System.monotonic_time(:millisecond)
    current = snapshot()
    changed = current != previous

    result =
      cond do
        changed or force ->
          send_event(socket, "sessions", payload(current))

        now - last_write >= @keepalive_ms ->
          # A bare comment line: keeps the socket warm and, more usefully,
          # surfaces a dead peer as a send error so this process can exit
          # instead of polling a log forever for nobody.
          :gen_tcp.send(socket, ": keepalive\n\n")

        true ->
          :nothing
      end

    case result do
      :ok ->
        Process.sleep(@poll_ms)
        loop(socket, current, now, false)

      :nothing ->
        Process.sleep(@poll_ms)
        loop(socket, current, last_write, false)

      {:error, _} ->
        :ok
    end
  end

  defp send_event(socket, name, data) do
    :gen_tcp.send(socket, ["event: ", name, "\ndata: ", data, "\n\n"])
  end

  defp payload(_snapshot) do
    {200, sessions} = API.sessions()
    {200, stats} = API.stats()
    Jason.encode!(%{sessions: sessions.sessions, stats: stats})
  end

  # Cheap change key. Reads events per session, which is the same work the
  # sessions endpoint does; at loopback scale with a handful of sessions this
  # is far below the cost of the browser rendering the result.
  defp snapshot do
    for id <- ShemSpolia.EventLog.known_session_ids() do
      case ShemSpolia.EventLog.read_session_events(id) do
        {:ok, events} ->
          {id, length(events), events |> List.last() |> then(&(&1 && &1.hash))}

        _ ->
          {id, 0, nil}
      end
    end
    |> Enum.sort()
  end
end
