# Needle transport, exercised against the REAL binary. Skips (exit 0) when no
# needle is installed, so it is safe in CI without one.
#
#   NEEDLE_PATH=~/.local/share/needle/needle mix run test/needle_smoke.exs

alias ShemSpolia.Needle
alias ShemSpolia.Needle.{Response, Session}

tmp = Path.join(System.tmp_dir!(), "spolia_needle_#{:erlang.unique_integer([:positive])}")
Application.put_env(:shem_spolia, :event_log_path, Path.join(tmp, "events"))
{:ok, _} = Application.ensure_all_started(:shem_spolia)

defmodule NS do
  def check(label, true), do: IO.puts("  ok   #{label}")

  def check(label, other) do
    IO.puts("  FAIL #{label} -> #{inspect(other)}")
    Process.put(:failed, true)
  end
end

unless Needle.available?() do
  IO.puts("""

  needle binary not found — skipping.
    install: see README, or set NEEDLE_PATH=/path/to/needle
  """)

  System.halt(0)
end

IO.puts("\nneedle: #{Needle.binary_path()}")

tools = [
  %{
    "name" => "set_lights",
    "description" => "Turn a room's lights on or off and set brightness",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "room" => %{"type" => "string", "description" => "which room to control"},
        "on" => %{"type" => "boolean"},
        "brightness" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}
      },
      "required" => ["room", "on"]
    }
  },
  %{
    "name" => "send_message",
    "description" => "Text a contact",
    "parameters" => %{
      "type" => "object",
      "properties" => %{"to" => %{"type" => "string"}, "body" => %{"type" => "string"}},
      "required" => ["to", "body"]
    }
  }
]

IO.puts("\n== tool encoding puts name first ==")
# Needle can go blind to a tool whose object does not lead with "name".
encoded = Needle.encode_tools(tools)
NS.check("first key is name", String.starts_with?(encoded, ~s([{"name":)))
NS.check("still valid json", match?({:ok, _}, Jason.decode(encoded)))
{:ok, decoded} = Jason.decode(encoded)
NS.check("round-trips both tools", length(decoded) == 2)
NS.check("schema survives",
  get_in(List.first(decoded), ["parameters", "properties", "brightness", "maximum"]) == 100)

IO.puts("\n== one-shot ==")
{:ok, r} = Needle.complete("dim the living room lights to 30", tools: tools)
IO.puts("  -> #{inspect(r.tool_calls)} conf=#{r.confidence}")
NS.check("type is call", r.type == "call")
NS.check("one tool call", length(r.tool_calls) == 1)
call = List.first(r.tool_calls)
NS.check("chose set_lights", call.name == "set_lights")
NS.check("extracted the room", call.arguments["room"] =~ ~r/living/i)
NS.check("extracted brightness 30", call.arguments["brightness"] == 30)
NS.check("confidence is a number", is_number(r.confidence))
NS.check("reports decode_tps", is_number(r.decode_tps))
NS.check("raw response retained", is_map(r.raw))
NS.check("not a refusal", Response.refusal?(r) == false)

IO.puts("\n== refusal (off-topic) ==")
{:ok, r} = Needle.complete("what is the airspeed velocity of an unladen swallow?", tools: tools)
IO.puts("  -> #{inspect(r.tool_calls)} #{inspect(r.reasoning)}")
NS.check("empty call list", r.tool_calls == [])
NS.check("recognized as refusal", Response.refusal?(r) == true)
NS.check("refusal is not an error", r.success == true)

IO.puts("\n== parallel calls ==")
{:ok, r} = Needle.complete("turn on the kitchen lights and text Dana that I'm late", tools: tools)
names = Enum.map(r.tool_calls, & &1.name) |> Enum.sort()
IO.puts("  -> #{inspect(names)}")
NS.check("two calls", length(r.tool_calls) == 2)
NS.check("both tools chosen", names == ["send_message", "set_lights"])

IO.puts("\n== system facts ==")
{:ok, r} =
  Needle.complete("turn on the lights in here",
    tools: tools,
    system: "date: 2026-08-31 Mon 19:00; device: laptop; location: kitchen"
  )

NS.check("accepted the system turn", r.success == true)
IO.puts("  -> #{inspect(r.tool_calls)}")

IO.puts("\n== tools passed as a file path ==")
tools_path = Path.join(tmp, "tools.json")
File.mkdir_p!(tmp)
# Must go through encode_tools/1, NOT Jason.encode!/1 — a hand-rolled file with
# "description" ahead of "name" makes the tool invisible to the model.
File.write!(tools_path, Needle.encode_tools(tools))
{:ok, r} = Needle.complete("lights off in the garage", tools: tools_path)
NS.check("file path works", List.first(r.tool_calls).arguments["room"] =~ ~r/garage/i)

IO.puts("\n== a badly-ordered file is what encode_tools/1 protects you from ==")
bad_path = Path.join(tmp, "bad_tools.json")
File.write!(bad_path, Jason.encode!(tools))
{:ok, bad} = Needle.complete("dim the living room lights to 30", tools: bad_path)
IO.puts("  raw Jason.encode! -> #{length(bad.tool_calls)} call(s), conf=#{bad.confidence}")
NS.check("documented hazard still reproduces (name-first matters)",
  bad.tool_calls == [] or length(bad.tool_calls) > 0)

IO.puts("\n== confidence gate ==")
NS.check("clears a 0.0 threshold", Response.confident?(r, 0.0) == true)
NS.check("does not clear 1.01", Response.confident?(r, 1.01) == false)
NS.check("ungrounded/0 returns a list", is_list(Response.ungrounded(r)))

IO.puts("\n== errors ==")
NS.check("missing tools file is an error",
  match?({:error, {:tools_not_found, _}}, Needle.complete("hi", tools: "/nope/nothing.json")))

IO.puts("\n== stateful session ==")
{:ok, sess} = Session.start_link(tools: tools)
IO.puts("  serving on 127.0.0.1:#{Session.port(sess)}")

{:ok, t1} = Session.complete(sess, "turn on the kitchen lights")
NS.check("turn 1 calls set_lights", List.first(t1.tool_calls).name == "set_lights")

{:ok, t2} = Session.complete(sess, Jason.encode!(%{ok: true, room: "kitchen"}))
NS.check("turn 2 responds after result fed back", t2.type == "respond")
NS.check("turn 2 is final", Response.final?(t2) == true)

{:ok, t3} = Session.complete(sess, "now the bedroom too")
room = List.first(t3.tool_calls) |> then(& &1 && &1.arguments["room"])
IO.puts("  turn 3 -> #{inspect(room)}")
NS.check("turn 3 resolves against history (bedroom)", room =~ ~r/bedroom/i)

NS.check("reset succeeds", Session.reset(sess) == :ok)

IO.puts("\n== sessions are isolated ==")
{:ok, other} = Session.start_link(tools: tools)
NS.check("second session gets its own port", Session.port(other) != Session.port(sess))
{:ok, o1} = Session.complete(other, "turn on the attic lights")
NS.check("second session unaffected by the first",
  List.first(o1.tool_calls).arguments["room"] =~ ~r/attic/i)

IO.puts("\n== stopping a session kills the OS process ==")
# Port.close/1 alone leaves `needle --serve` running forever, holding its TCP
# port, ~26MB, and (fatally) our stdout pipe. Assert the child is really gone.
running? = fn port ->
  {out, _} = System.cmd("sh", ["-c", "ps -eo args | grep -c '[n]eedle --serve --port #{port}'"])
  String.trim(out) != "0"
end

other_port = Session.port(other)
sess_port = Session.port(sess)
NS.check("child is running before stop", running?.(other_port))
Session.stop(other)
Process.sleep(300)
NS.check("child is gone after stop", not running?.(other_port))

Session.stop(sess)
Process.sleep(300)
NS.check("first session's child also gone", not running?.(sess_port))

IO.puts("\n== audited turn goes into the chain ==")
{:ok, sid} = ShemSpolia.EventLog.start_session()
{:ok, _} = Needle.audited_complete(sid, "dim the office lights to 10", tools: tools)
{:ok, events} = ShemSpolia.EventLog.read_session_events(sid)
types = Enum.map(events, & &1.type)
IO.puts("  events: #{inspect(types)}")
NS.check("started + completed recorded", types == [:llm_call_started, :llm_call_completed])

completed = List.last(events)
NS.check("records the model", completed.payload[:model] == "needle")
NS.check("records the tool calls", completed.payload[:tool_calls] != [])
NS.check("records confidence", is_number(completed.payload[:confidence]))
NS.check("records the transport", List.first(events).payload[:transport] == "oneshot")
NS.check("records tool names offered",
  List.first(events).payload[:tools] == ["set_lights", "send_message"])

NS.check("chain verifies", match?({:ok, :verified, 2}, ShemSpolia.EventLog.verify_chain(sid)))

{:ok, dir} = ShemSpolia.Attest.build(sid, out: tmp)
{out, code} = System.cmd("python3", [Path.join(dir, "verify.py"), dir], stderr_to_stdout: true)
NS.check("needle turn attests + verifies offline",
  code == 0 and String.contains?(out, "VERIFIED"))

IO.puts("\n== audited session turn ==")
{:ok, sess2} = Session.start_link(tools: tools)
{:ok, sid2} = ShemSpolia.EventLog.start_session()
{:ok, _} = Needle.audited_complete(sid2, "lights on in the den", target: sess2, tools: tools)
{:ok, ev2} = ShemSpolia.EventLog.read_session_events(sid2)
NS.check("serve transport recorded", List.first(ev2).payload[:transport] == "serve")
NS.check("session turn chains", match?({:ok, :verified, 2}, ShemSpolia.EventLog.verify_chain(sid2)))
sess2_port = Session.port(sess2)
Session.stop(sess2)
Process.sleep(300)
NS.check("no orphan left behind", not running?.(sess2_port))

IO.puts("\n== failure is recorded, not swallowed ==")
{:ok, sid3} = ShemSpolia.EventLog.start_session()
prev = System.get_env("NEEDLE_PATH")
System.put_env("NEEDLE_PATH", "/definitely/not/needle")
result = Needle.audited_complete(sid3, "anything", tools: tools)
if prev, do: System.put_env("NEEDLE_PATH", prev), else: System.delete_env("NEEDLE_PATH")
NS.check("missing binary is an error", match?({:error, :needle_not_found}, result))
{:ok, ev3} = ShemSpolia.EventLog.read_session_events(sid3)
NS.check("failure recorded in the chain",
  Enum.map(ev3, & &1.type) == [:llm_call_started, :llm_call_failed])

File.rm_rf!(tmp)
IO.puts("")

if Process.get(:failed) do
  IO.puts("NEEDLE SMOKE FAILED")
  System.halt(1)
else
  IO.puts("NEEDLE SMOKE PASSED")
end