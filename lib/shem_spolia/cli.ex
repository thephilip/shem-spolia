defmodule ShemSpolia.CLI do
  @moduledoc """
  escript entry point.

      shem_audit serve              # run the MCP auditor on stdio
      shem_audit attest <session>   # write a bundle for a session
      shem_audit verify <session>   # recompute the chain, print the verdict
      shem_audit sessions           # list known sessions
      shem_audit needle <tools.json> <query>
                                    # one audited Needle turn; prints the calls
                                    # and the session id holding the record
  """

  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:shem_spolia)

    case argv do
      # long-running: owns its own lifecycle, flushes when stdin closes
      ["serve" | _] ->
        ShemSpolia.MCP.Server.serve()
        ShemSpolia.EventLog.flush()

      ["attest", session | rest] ->
        one_shot(fn -> attest(session, rest) end)

      ["verify", session | _] ->
        one_shot(fn -> verify(session) end)

      ["sessions" | _] ->
        one_shot(&sessions/0)

      ["needle", tools, query | _] ->
        one_shot(fn -> needle(tools, query) end)

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

  defp sessions do
    case ShemSpolia.EventLog.known_session_ids() do
      [] -> IO.puts("(no sessions)")
      ids -> Enum.each(ids, &IO.puts/1)
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