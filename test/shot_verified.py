#!/usr/bin/env python3
"""Capture the verified-session view (default tab is whichever sorts first)."""
import base64, json, os, socket, struct, subprocess, sys, time
import urllib.request

PORT = 9335
URL, OUT = sys.argv[1], sys.argv[2]
SELECT = sys.argv[3] if len(sys.argv) > 3 else None

chrome = subprocess.Popen(
    ["chromium", "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
     f"--remote-debugging-port={PORT}", "--user-data-dir=/tmp/cdp-prof3",
     "--window-size=1280,1100", "about:blank"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

for _ in range(100):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=1); break
    except Exception: time.sleep(0.2)

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
while b"\r\n\r\n" not in buf: buf += sock.recv(4096)

def send(msg):
    d = json.dumps(msg).encode(); m = os.urandom(4); n = len(d)
    hd = struct.pack("!BB", 0x81, 0x80|n) if n < 126 else (
         struct.pack("!BBH", 0x81, 0x80|126, n) if n < 65536 else
         struct.pack("!BBQ", 0x81, 0x80|127, n))
    sock.send(hd + m + bytes(b ^ m[i%4] for i,b in enumerate(d)))

leftover = b""
def recv_frame():
    global leftover
    def need(n):
        global leftover
        while len(leftover) < n:
            c = sock.recv(65536)
            if not c: raise EOFError
            leftover += c
        o, leftover = leftover[:n], leftover[n:]
        return o
    _, b1 = need(2); ln = b1 & 0x7F
    if ln == 126: ln = struct.unpack("!H", need(2))[0]
    elif ln == 127: ln = struct.unpack("!Q", need(8))[0]
    return json.loads(need(ln))

_id=[0]
def call(m, **p):
    _id[0]+=1; send({"id":_id[0],"method":m,"params":p})
    while True:
        r = recv_frame()
        if r.get("id")==_id[0]: return r.get("result",{})

def ev(e):
    return call("Runtime.evaluate", expression=e, returnByValue=True,
                awaitPromise=True).get("result",{}).get("value")

try:
    call("Page.enable"); call("Runtime.enable")
    call("Page.navigate", url=URL); time.sleep(4)
    if SELECT:
        ev(f"""[...document.querySelectorAll('.tab')]
                .find(t=>t.textContent.includes('{SELECT}')).click()""")
        time.sleep(1.5)
    # expand one payload so the screenshot shows the drill-down state
    ev("document.querySelectorAll('.slipcard')[1] && document.querySelectorAll('.slipcard')[1].click()")
    time.sleep(0.6)
    print(json.dumps({
        "sid": ev("(document.querySelector('.cardhead .sid')||{}).textContent"),
        "disp": ev("(document.querySelector('.disp .val')||{}).textContent"),
        "entries": ev("document.querySelectorAll('.entry').length"),
        "payload_open": ev("!!document.querySelector('.payload')"),
    }, indent=2))
    shot = call("Page.captureScreenshot", format="png", captureBeyondViewport=True)
    open(OUT,"wb").write(base64.b64decode(shot["data"]))
    print("wrote", OUT)
finally:
    sock.close(); chrome.kill()
