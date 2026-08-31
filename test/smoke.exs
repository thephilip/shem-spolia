# End-to-end smoke: record a session, verify the chain, export a bundle, and
# hand it to verify.py — the actual trust anchor. Run with:
#   mix run test/smoke.exs

tmp = Path.join(System.tmp_dir!(), "spolia_smoke_#{:erlang.unique_integer([:positive])}")
Application.put_env(:shem_spolia, :event_log_path, Path.join(tmp, "events"))

{:ok, _} = Application.ensure_all_started(:shem_spolia)

defmodule Smoke do
  def check(label, true), do: IO.puts("  ok   #{label}")

  def check(label, other) do
    IO.puts("  FAIL #{label} -> #{inspect(other)}")
    Process.put(:failed, true)
  end
end

IO.puts("\n== record ==")
{:ok, sid} = ShemSpolia.EventLog.start_session()
IO.puts("  session #{sid}")

{:ok, _} =
  ShemSpolia.EventLog.append(sid, :llm_call_started, %{model: "needle", prompt: "turn on the kitchen lights"})

{:ok, turn} =
  ShemSpolia.EventLog.append(sid, :llm_call_completed, %{
    model: "needle",
    content: "",
    tool_calls: [%{name: "set_lights", arguments: %{room: "kitchen", state: "on"}}]
  })

{:ok, _} =
  ShemSpolia.EventLog.append(sid, :agent_tool_called, %{
    tool: "set_lights",
    arguments: %{room: "kitchen", state: "on"},
    api_key: %{"$sensitive" => "sk-should-never-appear"}
  })

{:ok, _} = ShemSpolia.EventLog.append(sid, :agent_tool_result, %{tool: "set_lights", ok: true})

{:ok, events} = ShemSpolia.EventLog.read_session_events(sid)
Smoke.check("5 events recorded", length(events) == 5 or length(events) == 4)
Smoke.check("event count is 4", length(events) == 4)

IO.puts("\n== redaction ==")
raw = inspect(events)
Smoke.check("secret absent from the log", not String.contains?(raw, "sk-should-never-appear"))
Smoke.check("redaction marker present", String.contains?(raw, "$redacted"))

IO.puts("\n== verify chain ==")
Smoke.check("chain verifies", match?({:ok, :verified, 4}, ShemSpolia.EventLog.verify_chain(sid)))

IO.puts("\n== attest bundle ==")
{:ok, dir} = ShemSpolia.Attest.build(sid, out: tmp)
IO.puts("  bundle #{dir}")

manifest = Path.join(dir, "manifest.json") |> File.read!() |> Jason.decode!()
Smoke.check("manifest has portable_head", is_binary(manifest["portable_head"]))
Smoke.check("manifest has beam_head", is_binary(manifest["beam_head"]))
Smoke.check("tool recorded in manifest", Enum.any?(manifest["tools"], &(&1["name"] == "set_lights")))
Smoke.check("tool status is missing (no resolver)",
  Enum.all?(manifest["tools"], &(&1["status"] == "missing")))

lines = Path.join(dir, "events.jsonl") |> File.read!() |> String.split("\n", trim: true)
Smoke.check("events.jsonl has 4 lines", length(lines) == 4)
Smoke.check("verify.py copied", File.exists?(Path.join(dir, "verify.py")))
Smoke.check("README.txt copied", File.exists?(Path.join(dir, "README.txt")))

IO.puts("\n== verify.py (the trust anchor) ==")
{out, code} = System.cmd("python3", [Path.join(dir, "verify.py"), dir], stderr_to_stdout: true)
out |> String.split("\n", trim: true) |> Enum.each(&IO.puts("  | #{&1}"))
Smoke.check("verify.py exits 0", code == 0)
Smoke.check("verify.py says VERIFIED", String.contains?(out, "VERIFIED"))

IO.puts("\n== tamper detection ==")
tampered = Path.join(tmp, "tampered")
File.cp_r!(dir, tampered)
evfile = Path.join(tampered, "events.jsonl")
File.read!(evfile) |> String.replace("kitchen", "bedroom") |> then(&File.write!(evfile, &1))
{tout, tcode} = System.cmd("python3", [Path.join(tampered, "verify.py"), tampered], stderr_to_stdout: true)
Smoke.check("tampered bundle exits nonzero", tcode != 0)
Smoke.check("tampered bundle reports mismatch", String.contains?(tout, "CHAIN MISMATCH"))

IO.puts("\n== fork ==")
{:ok, fork} = ShemSpolia.Fork.create(sid, turn.id, %{content: "I won't touch the lights.", tool_calls: []})
IO.puts("  fork #{fork.fork_session_id} (copied #{fork.copied})")
Smoke.check("fork point echoed", fork.fork_point == turn.id)
Smoke.check("fork chain verifies",
  match?({:ok, :verified, _}, ShemSpolia.EventLog.verify_chain(fork.fork_session_id)))

{:ok, fevents} = ShemSpolia.EventLog.read_session_events(fork.fork_session_id)
Smoke.check("fork starts with :fork_created", List.first(fevents).type == :fork_created)
Smoke.check("fork ends with :counterfactual_turn", List.last(fevents).type == :counterfactual_turn)
Smoke.check("fork copied 2 events + 2 markers", length(fevents) == 4)

{:ok, fdir} = ShemSpolia.Attest.build(fork.fork_session_id, out: tmp)
{fout, fcode} = System.cmd("python3", [Path.join(fdir, "verify.py"), fdir], stderr_to_stdout: true)
Smoke.check("fork bundle verifies offline", fcode == 0 and String.contains?(fout, "VERIFIED"))

IO.puts("\n== recall ==")
%{hits: hits} = ShemSpolia.Recall.Index.search("kitchen lights", 5)
Smoke.check("recall found something", hits != [])
top = List.first(hits)
Smoke.check("top hit is from our session", top && top.session_id in [sid, fork.fork_session_id])

IO.puts("\n== mcp router ==")
manifest_tools = ShemSpolia.MCP.Router.manifest() |> Enum.map(& &1["name"]) |> Enum.sort()
Smoke.check("four audit tools exposed",
  manifest_tools == ["audit.export_bundle", "audit.fork_here", "audit.recall", "audit.verify_chain"])

{:ok, vres} = ShemSpolia.MCP.Router.dispatch("audit.verify_chain", %{"session_id" => sid})
Smoke.check("audit.verify_chain says valid", vres.valid == true)

{:ok, rres} = ShemSpolia.MCP.Router.dispatch("audit.recall", %{"query" => "kitchen", "limit" => 3})
Smoke.check("audit.recall returns hits", rres.hits != [])
Smoke.check("recall hit carries a fork_point",
  Enum.any?(rres.hits, &(&1[:fork_point] != nil)))

Smoke.check("unknown tool is an error",
  match?({:error, _}, ShemSpolia.MCP.Router.dispatch("audit.nope", %{})))

File.rm_rf!(tmp)

IO.puts("")

if Process.get(:failed) do
  IO.puts("SMOKE FAILED")
  System.halt(1)
else
  IO.puts("SMOKE PASSED")
end