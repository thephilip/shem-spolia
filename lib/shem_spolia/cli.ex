defmodule ShemSpolia.CLI do
  @moduledoc """
  escript entry point.

      shem_audit serve              # run the MCP auditor on stdio
      shem_audit attest <session>   # write a bundle for a session
      shem_audit verify <session>   # recompute the chain, print the verdict
      shem_audit sessions           # list known sessions
      shem_audit web [--port N]     # serve the timeline UI on 127.0.0.1
      shem_audit needle <tools.json> <query>
                                    # one audited Needle turn; prints the calls
                                    # and the session id holding the record
      shem_audit record [--session ID] [--type T] [--quiet]
                                    # read one JSON object on stdin and append
                                    # it to a chain. Built for Claude Code's
                                    # PostToolUse hook; see README.
  """

  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:shem_spolia)

    case argv do
      # long-running: owns its own lifecycle, flushes when stdin closes
      ["serve" | _] ->
        ShemSpolia.MCP.Server.serve()
        ShemSpolia.EventLog.flush()

      ["web" | rest] ->
        web(rest)

      ["attest", session | rest] ->
        one_shot(fn -> attest(session, rest) end)

      ["verify", session | _] ->
        one_shot(fn -> verify(session) end)

      ["sessions" | _] ->
        one_shot(&sessions/0)

      ["needle", tools, query | _] ->
        one_shot(fn -> needle(tools, query) end)

      ["record" | rest] ->
        one_shot(fn -> record(rest) end)

      [] ->
        usage()

      ["help" | _] ->
        usage()

      other ->
        die("unknown command: #{Enum.join(other, " ")}")
    end
  end

  # DETS only guarantees durability on close, and an escript exits the moment
  # main/1 returns — no terminate callback runs. Without this flush, events
  # written by the command are still in the buffer and the file is left dirty,
  # so the session reopens as LEGACY · 0 and the record is gone.
  defp one_shot(fun) do
    fun.()
  after
    ShemSpolia.EventLog.flush()
  end

  defp attest(session, rest) do
    out = List.first(rest) || File.cwd!()

    case ShemSpolia.Attest.build(session, out: out) do
      {:ok, dir} ->
        IO.puts("attest bundle written: #{dir}")
        IO.puts("verify with:  python3 #{Path.join(dir, "verify.py")} #{dir}")

      {:error, reason} ->
        die("attest of #{session} failed: #{inspect(reason)}")
    end
  end

  defp verify(session) do
    case ShemSpolia.EventLog.verify_chain(session) do
      {:ok, :verified, n} ->
        IO.puts("VERIFIED · #{n} events")

      {:ok, :verified_gc, %{pruned: p, replayable: r}} ->
        IO.puts("VERIFIED (post-GC) · #{p} pruned, #{r} replayable")

      {:ok, :legacy, n} ->
        IO.puts("LEGACY (unhashed prefix) · #{inspect(n)}")

      {:error, {:broken_at, id}} ->
        die("CHAIN BROKEN at #{id}")

      {:error, :not_found} ->
        die("session not found: #{session}")
    end
  end

  defp needle(tools_path, query) do
    unless ShemSpolia.Needle.available?() do
      die("needle binary not found — set NEEDLE_PATH or put `needle` on PATH")
    end

    unless File.exists?(tools_path), do: die("no such tools file: #{tools_path}")

    {:ok, session_id} = ShemSpolia.EventLog.start_session()

    case ShemSpolia.Needle.audited_complete(session_id, query, tools: tools_path) do
      {:ok, response} ->
        if response.tool_calls == [] do
          IO.puts("no call — #{response.reasoning || "no declared tool serves this"}")
        else
          Enum.each(response.tool_calls, fn c ->
            IO.puts("#{c.name} #{Jason.encode!(c.arguments)}")
          end)
        end

        IO.puts("confidence: #{response.confidence}")
        IO.puts("recorded in: #{session_id}")

      {:error, reason} ->
        die("needle failed: #{inspect(reason)} (recorded in #{session_id})")
    end
  end

  # Recording must never take down the session it is recording. A hook that
  # exits nonzero interrupts the agent, so a malformed payload or a locked log
  # is a warning on stderr and exit 0 — the gap shows up as a missing event,
  # which is the honest failure mode. `die/1` is reserved for arguments the
  # user got wrong, which happens at setup time, not mid-session.
  defp record(args) do
    {session, type, quiet} = record_opts(args)

    case IO.read(:stdio, :eof) do
      :eof ->
        warn("record: empty stdin, nothing to record")

      {:error, reason} ->
        warn("record: stdin error: #{inspect(reason)}")

      raw ->
        case ShemSpolia.Ingest.ingest(raw, session: session, type: type) do
          {:ok, session_id, event_id} ->
            unless quiet, do: IO.puts("#{session_id} #{event_id}")

          {:error, :no_session} ->
            warn("record: no session_id in payload and no --session given")

          {:error, {:bad_session_id, id}} ->
            die("record: --session must match [A-Za-z0-9_.-]{1,96}, got: #{id}")

          {:error, reason} ->
            warn("record: not recorded: #{inspect(reason)}")
        end
    end
  end

  defp record_opts(args), do: record_opts(args, {nil, nil, false})

  defp record_opts([], acc), do: acc

  defp record_opts(["--session", v | rest], {_s, t, q}), do: record_opts(rest, {v, t, q})
  defp record_opts(["--type", v | rest], {s, _t, q}), do: record_opts(rest, {s, v, q})
  defp record_opts(["--quiet" | rest], {s, t, _q}), do: record_opts(rest, {s, t, true})

  defp record_opts([flag | _], _acc) when flag in ["--session", "--type"],
    do: die("record: #{flag} expects a value")

  defp record_opts([other | _], _acc), do: die("record: unknown option: #{other}")

  defp warn(msg) do
    IO.puts(:stderr, msg)
    :ok
  end

  defp sessions do
    case ShemSpolia.EventLog.known_session_ids() do
      [] -> IO.puts("(no sessions)")
      ids -> Enum.each(ids, &IO.puts/1)
    end
  end

  # Long-running like `serve`, but with nothing to read from stdin — so the
  # main process has to block on something. It sleeps rather than joining the
  # acceptor: the acceptor is spawn_link'd from here, so if it dies the link
  # takes this process down and the binary exits instead of idling with a dead
  # listener.
  defp web(args) do
    port =
      case args do
        ["--port", p | _] ->
          case Integer.parse(p) do
            {n, ""} when n >= 0 and n <= 65_535 -> n
            _ -> die("--port expects a number 0-65535, got: #{p}")
          end

        _ ->
          String.to_integer(System.get_env("SHEM_SPOLIA_WEB_PORT") || "4180")
      end

    case ShemSpolia.Web.Server.start(port: port) do
      {:ok, bound} ->
        IO.puts("shem-spolia web · http://127.0.0.1:#{bound}")
        IO.puts("log: #{ShemSpolia.EventLog.event_log_path()}")
        IO.puts("ctrl-c to stop")
        Process.sleep(:infinity)

      {:error, {:listen_failed, p, :eaddrinuse}} ->
        die("port #{p} is already in use — pass --port to pick another")

      {:error, reason} ->
        die("could not start web server: #{inspect(reason)}")
    end
  end

  defp usage do
    IO.puts(@moduledoc)
  end

  defp die(msg) do
    IO.puts(:stderr, msg)
    # flush before halting: System.halt/1 skips `after` blocks and terminate
    # callbacks, so an error path would otherwise leave DETS dirty.
    ShemSpolia.EventLog.flush()
    System.halt(2)
  end
end
