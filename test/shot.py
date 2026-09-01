#!/usr/bin/env python3
"""Screenshot + DOM assertions against a running shem_audit web server, over CDP.

Uses stdlib only (http.client + a raw websocket frame writer) so it works with
whatever Chromium is on the box and needs no node_modules. Not general purpose:
it drives one page, waits, asks for a few DOM facts, and captures the viewport.
"""
import base64, json, os, socket, struct, subprocess, sys, time
import http.client
import urllib.request

PORT = 9333
URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:4200/"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/custody-live.png"
HEIGHT = int(sys.argv[3]) if len(sys.argv) > 3 else 1700

chrome = subprocess.Popen(
    ["chromium", "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
     f"--remote-debugging-port={PORT}", "--user-data-dir=/tmp/cdp-prof",
     f"--window-size=1280,{HEIGHT}", "about:blank"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def wait_for_devtools():
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=1):
                return True
        except Exception:
            time.sleep(0.2)
    return False

if not wait_for_devtools():
    chrome.kill(); sys.exit("devtools never came up")

targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json"))
page = next(t for t in targets if t["type"] == "page")
ws_url = page["webSocketDebuggerUrl"]

# ── minimal websocket client ─────────────────────────────────────────────
host, rest = ws_url.split("://")[1].split("/", 1)
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
    data = json.dumps(msg).encode()
    mask = os.urandom(4)
    n = len(data)
    if n < 126:
        header = struct.pack("!BB", 0x81, 0x80 | n)
    elif n < 65536:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, n)
    else:
        header = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
    sock.send(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

leftover = b""
def recv_frame():
    global leftover
    def need(n):
        global leftover
        while len(leftover) < n:
            chunk = sock.recv(65536)
            if not chunk:
                raise EOFError
            leftover += chunk
        out, leftover = leftover[:n], leftover[n:]
        return out
    b0, b1 = need(2)
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack("!H", need(2))[0]
    elif ln == 127:
        ln = struct.unpack("!Q", need(8))[0]
    return json.loads(need(ln))

_id = [0]
def call(method, **params):
    _id[0] += 1
    send({"id": _id[0], "method": method, "params": params})
    while True:
        msg = recv_frame()
        if msg.get("id") == _id[0]:
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
            return msg.get("result", {})

def evaluate(expr):
    r = call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
    return r.get("result", {}).get("value")

try:
    call("Page.enable")
    call("Runtime.enable")
    call("Log.enable")
    call("Page.navigate", url=URL)
    time.sleep(4.5)

    facts = evaluate("""(() => ({
      tabs: document.querySelectorAll('.tab').length,
      entries: document.querySelectorAll('.entry').length,
      cut: document.querySelectorAll('.entry.cut').length,
      disp: (document.querySelector('.disp .val')||{}).textContent,
      feed: (document.querySelector('.docket .no b:last-of-type')||{}).textContent,
      counts: [...document.querySelectorAll('.field .v')].map(e=>e.textContent),
      font: getComputedStyle(document.body).fontFamily,
      fontLoaded: document.fonts ? document.fonts.check('12px "Courier Prime"') : null,
      bodyBg: getComputedStyle(document.body).backgroundColor,
      disabled: [...document.querySelectorAll('button.st')].map(b=>b.disabled),
      title: document.title,
      height: document.body.scrollHeight
    }))()""")
    print(json.dumps(facts, indent=2))

    shot = call("Page.captureScreenshot", format="png", captureBeyondViewport=True)
    with open(OUT, "wb") as f:
        f.write(base64.b64decode(shot["data"]))
    print("wrote", OUT)
finally:
    sock.close()
    chrome.kill()
