defmodule ShemSpolia.CLI do
  @moduledoc """
  escript entry point.

      shem_audit serve              # run the MCP auditor on stdio
      shem_audit attest <session>   # write a bundle for a session
      shem_audit verify <session>   # recompute the chain, print the verdict
      shem_audit sessions           # list known sessions
  """

  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:shem_spolia)

    case argv do
      ["serve" | _] -> ShemSpolia.MCP.Server.serve()
      ["attest", session | rest] -> attest(session, rest)
      ["verify", session | _] -> verify(session)
      ["sessions" | _] -> sessions()
      [] -> usage()
      ["help" | _] -> usage()
      other -> die("unknown command: #{Enum.join(other, " ")}")
    end
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
    System.halt(2)
  end
end