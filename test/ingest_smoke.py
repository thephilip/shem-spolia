#!/usr/bin/env python3
"""Drive `./shem_audit record` the way Claude Code's PostToolUse hook does.

The hook contract is the thing under test: a JSON object on stdin, one process
per tool call, and — critically — never a nonzero exit for a bad payload,
because a hook that fails interrupts the agent it is recording.

Ends by proving the point of the whole exercise: edit a recorded command in an
exported bundle and the offline verifier refuses it.
"""
import glob, hashlib, json, os, shutil, subprocess, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(os.path.dirname(ROOT), "shem_audit")

failures = []

def check(label, cond, detail=""):
    if cond:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label} {detail}")
        failures.append(label)

tmp = tempfile.mkdtemp(prefix="spolia_ingest_")
env = dict(os.environ, SHEM_SPOLIA_EVENT_LOG_PATH=os.path.join(tmp, "events"))

def record(payload, *args):
    """One `shem_audit record`, as the hook invokes it."""
    raw = payload if isinstance(payload, str) else json.dumps(payload)
    p = subprocess.run([BIN, "record", *args], input=raw, capture_output=True,
                       text=True, env=env)
    return p

def run(*args):
    return subprocess.run([BIN, *args], capture_output=True, text=True, env=env)

def derive(external):
    return "ses_" + hashlib.sha256(external.encode()).hexdigest()[:16]

# A realistic PostToolUse payload: Claude Code sends the whole tool envelope.
UUID = "9f8a1c22-3d4e-4f50-a1b2-c3d4e5f60718"
SES = derive(UUID)

def hook(tool_name, tool_input, response="", session=UUID):
    return {
        "session_id": session,
        "transcript_path": "/home/u/.claude/projects/x/transcript.jsonl",
        "cwd": "/home/u/project",
        "hook_event_name": "PostToolUse",
        "tool_name": tool_name,
        "tool_input": tool_input,
        "tool_response": response,
    }

print("\n== the hook contract ==")
p = record(hook("Bash", {"command": "rm -rf /tmp/junk", "description": "clean"},
                {"stdout": "", "exit_code": 0}))
check("exit 0", p.returncode == 0, p.stderr)
out = p.stdout.split()
check("prints session and event id", len(out) == 2 and out[0] == SES, p.stdout)
check("session derived from the client's session_id", out[0] == SES, out)

p = record(hook("Edit", {"file_path": "/home/u/project/a.ex", "old_string": "x"}))
check("second call joins the same chain", p.stdout.split()[0] == SES, p.stdout)

p = record(hook("mcp__github__search_repositories", {"query": "elixir"}, "3 hits"))
check("MCP tool calls record too", p.returncode == 0 and p.stdout.split()[0] == SES)

p = record(hook("Read", {"file_path": "/etc/hosts"}), "--quiet")
check("--quiet prints nothing", p.stdout == "", repr(p.stdout))

print("\n== failure is never the agent's problem ==")
for label, payload, args in [
    ("malformed JSON exits 0", "not json{", ()),
    ("empty stdin exits 0", "", ()),
    ("JSON array exits 0", "[1,2]", ()),
    ("no session_id exits 0", {"tool_name": "Bash"}, ()),
]:
    p = record(payload, *args)
    check(label, p.returncode == 0, f"rc={p.returncode} {p.stderr}")
    check(f"  ...and says why on stderr", p.stderr.strip() != "")

print("\n== a session id cannot escape the log directory ==")
for bad in ["../../etc/passwd", "a/b", "with space", ""]:
    p = record({"a": 1}, "--session", bad)
    check(f"rejects --session {bad!r}", p.returncode == 2, f"rc={p.returncode}")
check("no stray files above the log dir",
      not glob.glob(os.path.join(tmp, "*.dets")))

p = record({"a": 1}, "--session")
check("--session with no value is an argument error", p.returncode == 2)
p = record({"a": 1}, "--bogus")
check("unknown option is an argument error", p.returncode == 2)

print("\n== oversized payloads do not enter the chain whole ==")
big = "A" * 200_000
p = record(hook("Read", {"file_path": "/big"}, big))
check("large tool_response still records", p.returncode == 0, p.stderr)
sizes = [os.path.getsize(f) for f in glob.glob(os.path.join(tmp, "events", "*.dets"))]
check("log did not absorb 200KB", max(sizes) < 200_000, sizes)

print("\n== the chain ==")
p = run("verify", SES)
check("session verifies", "VERIFIED" in p.stdout, p.stdout + p.stderr)
check("holds every recorded event", "5 events" in p.stdout, p.stdout)

p = run("sessions")
check("session is listed", SES in p.stdout, p.stdout)

print("\n== bundle, and the claim itself ==")
out_dir = os.path.join(tmp, "bundle")
p = run("attest", SES, out_dir)
check("attest succeeds", p.returncode == 0, p.stdout + p.stderr)
bundles = glob.glob(os.path.join(out_dir, "*"))
check("one bundle written", len(bundles) == 1, bundles)
b = bundles[0]

manifest = json.load(open(os.path.join(b, "manifest.json")))
names = sorted(t["name"] for t in manifest["tools"])
check("hook-recorded tools appear in the manifest",
      "Bash" in names and "mcp__github__search_repositories" in names, names)
check("tools with no configured resolver are honest about it",
      all(t["status"] == "missing" for t in manifest["tools"]))

verify_py = os.path.join(b, "verify.py")
p = subprocess.run(["python3", verify_py, b], capture_output=True, text=True)
check("offline verify passes", "VERIFIED" in p.stdout and p.returncode == 0,
      p.stdout + p.stderr)

# The whole product in one assertion: rewrite what the agent was recorded
# doing, and the bundle stops verifying.
events = os.path.join(b, "events.jsonl")
original = open(events).read()
check("the dangerous command is in the record", "rm -rf /tmp/junk" in original)
open(events, "w").write(original.replace("rm -rf /tmp/junk", "ls /tmp/junk"))

p = subprocess.run(["python3", verify_py, b], capture_output=True, text=True)
check("rewriting a recorded command breaks the chain",
      "CHAIN MISMATCH" in p.stdout, p.stdout)
check("and fails loudly", "FAILED" in p.stdout and p.returncode != 0, p.returncode)

shutil.rmtree(tmp, ignore_errors=True)

print()
if failures:
    print(f"FAILED ({len(failures)}): " + ", ".join(failures))
    raise SystemExit(1)
print("all checks passed")
