#!/usr/bin/env python3
"""Drive ./shem_audit serve over real stdio as an MCP client would.

Speaks newline-delimited JSON-RPC, exercises initialize / tools/list /
tools/call, then verifies the exported bundle with verify.py.
"""
import json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(os.path.dirname(ROOT), "shem_audit")

failures = []

def check(label, cond, detail=""):
    if cond:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label} {detail}")
        failures.append(label)

tmp = tempfile.mkdtemp(prefix="spolia_mcp_")
env = dict(os.environ, SHEM_SPOLIA_EVENT_LOG_PATH=os.path.join(tmp, "events"))

proc = subprocess.Popen(
    [BIN, "serve"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, bufsize=1, env=env,
)

def rpc(method, params=None, rid=[0]):
    rid[0] += 1
    req = {"jsonrpc": "2.0", "id": rid[0], "method": method}
    if params is not None:
        req["params"] = params
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        err = proc.stderr.read()
        raise SystemExit(f"server closed stdout. stderr:\n{err}")
    return json.loads(line)

def tool(name, args):
    r = rpc("tools/call", {"name": name, "arguments": args})
    content = r["result"]["content"][0]["text"]
    is_error = r["result"]["isError"]
    return (json.loads(content) if not is_error else content), is_error

print("\n== initialize ==")
r = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}})
check("serverInfo.name is shem-spolia", r["result"]["serverInfo"]["name"] == "shem-spolia")
check("declares tools capability", "tools" in r["result"]["capabilities"])

print("\n== tools/list ==")
r = rpc("tools/list")
names = sorted(t["name"] for t in r["result"]["tools"])
check("four audit tools", names == [
    "audit.export_bundle", "audit.fork_here", "audit.recall", "audit.verify_chain"], names)
check("every tool has a schema",
      all("inputSchema" in t and t["description"] for t in r["result"]["tools"]))

print("\n== notifications are not answered ==")
proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
proc.stdin.flush()
r = rpc("ping")
check("ping answered after notification (no desync)", r.get("result") == {})

print("\n== error handling ==")
r = rpc("nope/nope")
check("unknown method -> -32601", r["error"]["code"] == -32601)
payload, is_err = tool("audit.verify_chain", {"session_id": "ses_does_not_exist"})
check("missing session -> isError", is_err is True)
payload, is_err = tool("audit.fork_here", {"session_id": "x"})
check("missing required arg -> isError", is_err is True)

print("\n== the auditor audits itself ==")
# ses_TOOL_INVOCATIONS is opened by serve(); the calls above are in it already.
payload, is_err = tool("audit.verify_chain", {"session_id": "ses_TOOL_INVOCATIONS"})
check("invocation log exists and verifies", not is_err and payload["valid"] is True, payload)
n_before = payload.get("events")
payload, _ = tool("audit.verify_chain", {"session_id": "ses_TOOL_INVOCATIONS"})
check("invocation log grew with each call", payload["events"] > n_before,
      f"{n_before} -> {payload['events']}")

print("\n== export + offline verify ==")
payload, is_err = tool("audit.export_bundle",
                       {"session_id": "ses_TOOL_INVOCATIONS", "out_dir": tmp})
check("export returned a bundle path", not is_err and os.path.isdir(payload["bundle_path"]), payload)
bundle = payload["bundle_path"]
check("export suggests a verify command", payload["verify_command"].startswith("python3 "))

out = subprocess.run([sys.executable, os.path.join(bundle, "verify.py"), bundle],
                     capture_output=True, text=True)
for line in out.stdout.strip().splitlines():
    print(f"  | {line}")
check("verify.py exits 0 on the exported bundle", out.returncode == 0)

print("\n== fork ==")
# fork the invocation log at its latest event
payload, is_err = tool("audit.fork_here", {
    "session_id": "ses_TOOL_INVOCATIONS",
    "alt_response": {"content": "counterfactual", "tool_calls": []},
})
check("fork created", not is_err and payload["fork_session_id"].startswith("ses_fork_"), payload)
fork_id = payload["fork_session_id"]
payload, is_err = tool("audit.verify_chain", {"session_id": fork_id})
check("forked chain verifies", not is_err and payload["valid"] is True, payload)

print("\n== recall ==")
# NOTE: ses_TOOL_INVOCATIONS is deliberately NOT in the corpus — the auditor's
# own instrument log is not a memory. The fork above is a real session, so it
# is what recall should find.
payload, is_err = tool("audit.recall", {"query": "verify_chain", "limit": 5})
check("recall returns hits", not is_err and payload["hits"], payload)
check("hits carry snippets", all(h.get("snippet") for h in payload["hits"]))
check("invocation log excluded from corpus",
      all(h["session_id"] != "ses_TOOL_INVOCATIONS" for h in payload["hits"]))

proc.stdin.close()
proc.wait(timeout=10)
shutil.rmtree(tmp, ignore_errors=True)

print()
if failures:
    print(f"MCP SMOKE FAILED ({len(failures)}): {', '.join(failures)}")
    sys.exit(1)
print("MCP SMOKE PASSED")