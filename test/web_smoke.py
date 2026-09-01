#!/usr/bin/env python3
"""Web smoke: drive the BUILT shem_audit binary over real HTTP.

Deliberately not `mix run`. Phase 0 and 1 each shipped a bug that only exists
in the escript (priv_dir failing, DETS never flushing), so the web surface gets
tested the same way: build it, run it as a subprocess, talk to it over a socket.

Stdlib only — no requests, no pytest.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "shem_audit")

PASS, FAIL = 0, []

def check(name, got, want):
    global PASS
    if got == want:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL.append(name)
        print(f"  FAIL {name}: {got!r} != {want!r}")

def check_that(name, cond, detail=""):
    global PASS
    if cond:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL.append(name)
        print(f"  FAIL {name} {detail}")

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p

def req(url, method="GET", payload=None, headers=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(url, data=data, method=method,
                               headers=headers or ({"Content-Type": "application/json"} if data else {}))
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            body = resp.read()
            return resp.status, dict(resp.headers), body
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()

def jreq(url, method="GET", payload=None):
    status, headers, body = req(url, method, payload)
    try:
        return status, headers, json.loads(body)
    except Exception:
        return status, headers, None


if not os.path.exists(BIN):
    sys.exit(f"no binary at {BIN} — run: MIX_ENV=prod mix escript.build")

logdir = tempfile.mkdtemp(prefix="spolia-web-smoke-")
bundles = tempfile.mkdtemp(prefix="spolia-web-bundles-")
port = free_port()
env = dict(os.environ, SHEM_SPOLIA_EVENT_LOG_PATH=logdir)

print(f"log dir: {logdir}\nport:    {port}\n")

# ── seed a session through the MCP surface, so the web tests read data that
#    was written by the binary itself rather than by this script ────────────
mcp = subprocess.Popen([BIN, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                       env=env, text=True, bufsize=1)

def rpc(method, params=None, _id=[0]):
    _id[0] += 1
    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": _id[0],
                                "method": method, "params": params or {}}) + "\n")
    mcp.stdin.flush()
    while True:
        line = mcp.stdout.readline()
        if not line:
            raise SystemExit("mcp server died")
        msg = json.loads(line)
        if msg.get("id") == _id[0]:
            return msg

rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "web-smoke", "version": "0"}})
rpc("tools/list")
mcp.stdin.close()
mcp.wait(timeout=15)

# The MCP run recorded its own invocations; that gives us a real session on disk.
sessions_out = subprocess.run([BIN, "sessions"], env=env, capture_output=True, text=True)
seeded = [s for s in sessions_out.stdout.split() if s.startswith("ses_")]
print(f"seeded sessions: {seeded}\n")

# ── start the web server ──────────────────────────────────────────────────
srv = subprocess.Popen([BIN, "web", "--port", str(port)], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
base = f"http://127.0.0.1:{port}"

ready = False
for _ in range(80):
    try:
        urllib.request.urlopen(base + "/api/stats", timeout=1)
        ready = True
        break
    except Exception:
        if srv.poll() is not None:
            print(srv.stdout.read())
            sys.exit("server exited during startup")
        time.sleep(0.25)

if not ready:
    srv.kill()
    sys.exit("server never became ready")

try:
    print("static assets")
    for path, ctype in [("/", "text/html"), ("/app.css", "text/css"),
                        ("/app.js", "text/javascript"), ("/vendor/preact.js", "text/javascript"),
                        ("/fonts/CourierPrime-Regular.woff2", "font/woff2"),
                        ("/fonts/OFL.txt", "text/plain")]:
        st, hd, body = req(base + path)
        check(f"GET {path}", st, 200)
        check_that(f"{path} content-type", ctype in hd.get("Content-Type", ""),
                   hd.get("Content-Type"))
        check_that(f"{path} non-empty", len(body) > 100, f"{len(body)} bytes")

    # The escript has no unpacked priv dir; a binary asset proves the embedding
    # survived the archive rather than being read off disk.
    _, _, woff = req(base + "/fonts/CourierPrime-Bold.woff2")
    check("woff2 magic bytes", woff[:4], b"wOF2")

    print("\nsecurity posture")
    _, hd, _ = req(base + "/")
    csp = hd.get("Content-Security-Policy", "")
    check_that("CSP present", "default-src 'self'" in csp, csp)
    check_that("CSP forbids inline script", "'unsafe-inline'" not in csp, csp)
    check_that("CSP confines connections", "connect-src 'self'" in csp, csp)
    check("nosniff", hd.get("X-Content-Type-Options"), "nosniff")
    st, _, _ = req(base + "/fonts/..%2f..%2fmix.exs")
    check_that("no path traversal via fonts", st == 404, st)

    print("\napi")
    st, _, stats = jreq(base + "/api/stats")
    check("GET /api/stats", st, 200)
    check_that("stats reports log path", stats["log_path"] == logdir, stats["log_path"])
    check_that("stats counts sessions", stats["sessions"] >= 1, stats)

    st, _, ss = jreq(base + "/api/sessions")
    check("GET /api/sessions", st, 200)
    check_that("sessions listed", len(ss["sessions"]) >= 1, ss)
    sid = ss["sessions"][0]["id"]

    st, _, evs = jreq(f"{base}/api/sessions/{sid}/events")
    check("GET events", st, 200)
    check_that("events carry hashes", all(e["hash"] for e in evs["events"]), evs)

    st, _, v = jreq(f"{base}/api/sessions/{sid}/verify")
    check("GET verify", st, 200)
    check("chain verified", v["state"], "verified")

    st, _, missing = jreq(f"{base}/api/sessions/ses_does_not_exist/verify")
    check("verify unknown session is 404", st, 404)

    print("\nerror handling")
    st, _, _ = jreq(base + "/api/nope")
    check("unknown endpoint 404", st, 404)
    st, _, _ = jreq(base + "/api/sessions", method="DELETE")
    check("wrong method 405", st, 405)
    st, _, body = req(f"{base}/api/sessions/{sid}/fork", "POST", None,
                      {"Content-Type": "application/json"})
    st, _, j = jreq(f"{base}/api/recall")
    check("recall without query 422", st, 422)

    # a non-object JSON body must be refused, not coerced
    raw = urllib.request.Request(f"{base}/api/sessions/{sid}/fork", data=b"[1,2,3]",
                                 method="POST", headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(raw, timeout=10)
        check_that("array body refused", False, "accepted")
    except urllib.error.HTTPError as e:
        check("array body refused", e.code, 422)

    print("\nattest")
    st, _, att = jreq(f"{base}/api/sessions/{sid}/attest", "POST", {"out_dir": bundles})
    check("POST attest", st, 201)
    check_that("bundle dir exists", os.path.isdir(att["bundle_path"]), att["bundle_path"])
    for f in ["events.jsonl", "manifest.json", "verify.py", "README.txt", "tools.sha256"]:
        check_that(f"bundle has {f}", os.path.exists(os.path.join(att["bundle_path"], f)))

    # The bundle must verify with stdlib python and NO shem_audit involvement.
    vp = subprocess.run([sys.executable, os.path.join(att["bundle_path"], "verify.py"),
                         att["bundle_path"]], capture_output=True, text=True)
    check("verify.py exit code", vp.returncode, 0)
    check_that("verify.py says VERIFIED", "VERIFIED" in vp.stdout, vp.stdout)

    print("\nfork")
    st, _, fk = jreq(f"{base}/api/sessions/{sid}/fork", "POST",
                     {"alt_response": {"role": "assistant", "content": "alternative"}})
    check("POST fork", st, 201)
    fork_id = fk["fork_session_id"]
    check("fork verifies on its own chain", fk["verify"]["state"], "verified")
    st, _, fev = jreq(f"{base}/api/sessions/{fork_id}/events")
    check("fork first event is fork_created", fev["events"][0]["type"], "fork_created")
    check_that("fork records its parent",
               fev["events"][0]["payload"]["parent_session"] == sid, fev["events"][0])

    print("\nrecall")
    st, _, rc = jreq(base + "/api/recall?q=tools&limit=5")
    check("GET recall", st, 200)
    check_that("recall hits are shaped", all("snippet" in h for h in rc["hits"]), rc)

    print("\ntamper detection (the point of the tool)")
    # Corrupt a bundle's evidence and confirm the offline verifier rejects it.
    ev_path = os.path.join(att["bundle_path"], "events.jsonl")
    original = open(ev_path).read()
    open(ev_path, "w").write(original.replace("tools/list", "tools/EVIL", 1)
                             if "tools/list" in original else original[:-2] + "X\n")
    vp2 = subprocess.run([sys.executable, os.path.join(att["bundle_path"], "verify.py"),
                          att["bundle_path"]], capture_output=True, text=True)
    check_that("tampered bundle fails", vp2.returncode != 0, vp2.returncode)
    check_that("tampered bundle says MISMATCH",
               "MISMATCH" in (vp2.stdout + vp2.stderr).upper(), vp2.stdout + vp2.stderr)
    open(ev_path, "w").write(original)

    print("\nsse stream")
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.send(f"GET /api/stream HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
    s.settimeout(12)
    chunk = b""
    deadline = time.time() + 12
    while b"\n\n" not in chunk and time.time() < deadline:
        try:
            chunk += s.recv(65536)
        except socket.timeout:
            break
    s.close()
    text = chunk.decode("utf-8", "replace")
    check_that("stream is event-stream", "text/event-stream" in text, text[:200])
    check_that("stream sends a sessions event", "event: sessions" in text, text[:400])
    payload_line = [l for l in text.split("\n") if l.startswith("data: ")]
    check_that("stream payload parses", bool(payload_line) and
               "sessions" in json.loads(payload_line[0][6:]), text[:400])

    print("\nloopback enforcement")
    # The server must be reachable on loopback and bound nowhere else.
    out = subprocess.run(["ss", "-ltnp"], capture_output=True, text=True).stdout
    bound = [l for l in out.splitlines() if f":{port}" in l]
    check_that("bound to 127.0.0.1 only",
               bool(bound) and all("127.0.0.1" in l for l in bound), bound)

finally:
    srv.terminate()
    try:
        srv.wait(timeout=10)
    except subprocess.TimeoutExpired:
        srv.kill()
    shutil.rmtree(logdir, ignore_errors=True)
    shutil.rmtree(bundles, ignore_errors=True)

print(f"\n{PASS} passed, {len(FAIL)} failed")
if FAIL:
    for f in FAIL:
        print(f"  - {f}")
    sys.exit(1)
