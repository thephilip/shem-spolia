#!/usr/bin/env python3
"""Interaction driver: clicks through the CUSTODY UI over CDP and reports state.

Same stdlib CDP client as shot.py, but scripted: select a session, expand an
entry, run attest, open the fork modal, submit a branch. Prints DOM facts after
each step so failures name the step that broke.
"""
import base64, json, os, socket, struct, subprocess, sys, time
import urllib.request

PORT = 9334
URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:4201/"

chrome = subprocess.Popen(
    ["chromium", "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
     f"--remote-debugging-port={PORT}", "--user-data-dir=/tmp/cdp-prof2",
     "--window-size=1280,1400", "about:blank"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def wait_devtools():
    for _ in range(100):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=1)
            return True
        except Exception:
            time.sleep(0.2)
    return False

if not wait_devtools():
    chrome.kill(); sys.exit("devtools never came up")

page = next(t for t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json"))
            if t["type"] == "page")
host, rest = page["webSocketDebuggerUrl"].split("://")[1].split("/", 1)
h, p = host.split(":")
sock = socket.create_connection((h, int(p)))
key = base64.b64encode(os.urandom(16)).decode()
sock.send((f"GET /{rest} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
           f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += sock.recv(4096)

def send(msg):
    data = json.dumps(msg).encode(); mask = os.urandom(4); n = len(data)
    if n < 126: header = struct.pack("!BB", 0x81, 0x80 | n)
    elif n < 65536: header = struct.pack("!BBH", 0x81, 0x80 | 126, n)
    else: header = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
    sock.send(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

leftover = b""
def recv_frame():
    global leftover
    def need(n):
        global leftover
        while len(leftover) < n:
            c = sock.recv(65536)
            if not c: raise EOFError
            leftover += c
        out, leftover = leftover[:n], leftover[n:]
        return out
    b0, b1 = need(2); ln = b1 & 0x7F
    if ln == 126: ln = struct.unpack("!H", need(2))[0]
    elif ln == 127: ln = struct.unpack("!Q", need(8))[0]
    return json.loads(need(ln))

_id = [0]
def call(method, **params):
    _id[0] += 1
    send({"id": _id[0], "method": method, "params": params})
    while True:
        m = recv_frame()
        if m.get("id") == _id[0]:
            if "error" in m: raise RuntimeError(f"{method}: {m['error']}")
            return m.get("result", {})

def ev(expr):
    r = call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
    if "exceptionDetails" in r:
        raise RuntimeError(r["exceptionDetails"].get("text"))
    return r.get("result", {}).get("value")

FAIL = []
def check(name, got, want):
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {got!r}" + ("" if ok else f" (want {want!r})"))
    if not ok: FAIL.append(name)

try:
    call("Page.enable"); call("Runtime.enable")
    call("Page.navigate", url=URL)
    time.sleep(4)

    # ── 1. verified session ──────────────────────────────────────────────
    ev("""[...document.querySelectorAll('.tab')]
           .find(t=>t.textContent.includes('ses_c1332')).click()""")
    time.sleep(1.2)
    check("verified session disposition",
          ev("document.querySelector('.disp .val').textContent"), "verified")
    check("entries rendered", ev("document.querySelectorAll('.entry').length"), 4)
    check("no cut thread on verified", ev("document.querySelectorAll('.entry.cut').length"), 0)
    check("head annotation present",
          ev("!!document.querySelector('.margin-note')"), True)
    check("actions enabled",
          ev("[...document.querySelectorAll('button.st')].map(b=>b.disabled)"),
          [False, False, False])

    # ── 2. expand a payload ──────────────────────────────────────────────
    ev("document.querySelectorAll('.slipcard')[1].click()")
    time.sleep(0.4)
    check("payload expands", ev("!!document.querySelector('.payload')"), True)
    check("payload has json",
          ev("(document.querySelector('.payload')||{}).textContent.includes('lights.set')"), True)
    ev("document.querySelectorAll('.slipcard')[1].click()")
    time.sleep(0.3)
    check("payload collapses", ev("!!document.querySelector('.payload')"), False)

    # ── 3. re-verify ─────────────────────────────────────────────────────
    ev("""[...document.querySelectorAll('button.st')]
           .find(b=>b.textContent.trim()==='re-verify').click()""")
    time.sleep(1.5)
    check("re-verify finding shown",
          ev("(document.querySelector('.finding.ok b')||{}).textContent"),
          "Chain re-verified.")

    # ── 4. attest ────────────────────────────────────────────────────────
    ev("""[...document.querySelectorAll('button.st')]
           .find(b=>b.textContent.trim()==='issue bundle').click()""")
    time.sleep(2.5)
    check("bundle issued",
          ev("(document.querySelector('.finding.ok b')||{}).textContent"), "Bundle issued.")
    check("verify command shown",
          ev("((document.querySelector('.finding .path')||{}).textContent||'').includes('verify.py')"),
          True)
    check("missing tool source reported",
          ev("((document.querySelector('.finding')||{}).textContent||'').includes('MISSING')"),
          True)

    # ── 5. fork: bad JSON is refused before it reaches the server ────────
    ev("""[...document.querySelectorAll('button.st')]
           .find(b=>b.textContent.trim()==='fork here').click()""")
    time.sleep(0.6)
    check("fork modal open", ev("!!document.querySelector('.modal')"), True)
    ev("""(() => {
        const ta = document.querySelector('.modal textarea');
        const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;
        set.call(ta, '{ not json');
        ta.dispatchEvent(new Event('input', {bubbles:true}));
    })()""")
    time.sleep(0.3)
    ev("""[...document.querySelectorAll('.modal button.st')]
           .find(b=>b.textContent.trim()==='create branch').click()""")
    time.sleep(0.6)
    check("bad JSON refused client-side",
          ev("((document.querySelector('.modal .err')||{}).textContent||'').includes('Not valid JSON')"),
          True)
    check("modal still open after error", ev("!!document.querySelector('.modal')"), True)

    # ── 6. fork: real branch ─────────────────────────────────────────────
    ev("""(() => {
        const ta = document.querySelector('.modal textarea');
        const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;
        set.call(ta, JSON.stringify({role:"assistant",content:"refused: policy"}));
        ta.dispatchEvent(new Event('input', {bubbles:true}));
    })()""")
    time.sleep(0.3)
    ev("""[...document.querySelectorAll('.modal button.st')]
           .find(b=>b.textContent.trim()==='create branch').click()""")
    time.sleep(3)
    check("modal closed after fork", ev("!!document.querySelector('.modal')"), False)
    check("branch finding shown",
          ev("(document.querySelector('.finding.ok b')||{}).textContent"), "Branch created.")
    check("selected switched to the branch",
          ev("(document.querySelector('.cardhead .sid')||{}).textContent.startsWith('ses_fork_')"),
          True)
    check("branch verifies on its own chain",
          ev("document.querySelector('.disp .val').textContent"), "verified")
    check("branch first entry is fork_created",
          ev("(document.querySelector('.entry .ty')||{}).textContent"), "fork created")

    # ── 7. recall ────────────────────────────────────────────────────────
    ev("""(() => {
        const i = document.querySelector('.search input');
        const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
        set.call(i, 'kitchen lights');
        i.dispatchEvent(new Event('input', {bubbles:true}));
    })()""")
    time.sleep(2)
    check("recall returns hits", ev("document.querySelectorAll('.hit').length > 0"), True)
    check("broken session listed as excluded",
          ev("""[...document.querySelectorAll('.skipped')]
                 .some(e=>e.textContent.includes('ses_tamper'))"""), True)
    check("no hit comes from the tampered session",
          ev("""[...document.querySelectorAll('.hit .sid')]
                 .every(e=>!e.textContent.includes('ses_tamper'))"""), True)

    # clicking a hit selects its session
    ev("document.querySelector('.hit').click()")
    time.sleep(1.2)
    check("hit click selects session",
          ev("!!document.querySelector('.cardhead .sid')"), True)

    shot = call("Page.captureScreenshot", format="png", captureBeyondViewport=True)
    open("/tmp/custody-interact.png","wb").write(base64.b64decode(shot["data"]))
    print("\nwrote /tmp/custody-interact.png")

finally:
    sock.close(); chrome.kill()

print()
if FAIL:
    print(f"{len(FAIL)} FAILED: {', '.join(FAIL)}")
    sys.exit(1)
print("all interaction checks passed")
