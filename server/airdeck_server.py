#!/usr/bin/env python3
"""AirDeck PC server.

Receives touchpad / gyroscope / keyboard events from the AirDeck Android app
and injects them through /dev/uinput (works on Wayland and X11).  Also relays
push-to-talk audio in both directions using PipeWire's pw-cat.

No third-party Python packages are required.
"""
import argparse
import fcntl
import json
import os
import random
import socket
import struct
import subprocess
import sys
import threading
import time
import webbrowser
from urllib.parse import urlencode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TCP_PORT = 47800        # phone <-> PC control + audio
DISCOVERY_PORT = 47801  # UDP discovery
UI_PORT = 47802         # local browser page (127.0.0.1 only)
SAMPLE_RATE = 16000     # mono s16le for push-to-talk
CONFIG_DIR = os.path.expanduser("~/.config/airdeck")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- protocol
# Each frame: u8 type | u32 big-endian payload length | payload
T_AUTH, T_MOVE, T_BUTTON, T_CLICK, T_SCROLL, T_TEXT, T_KEY = 1, 2, 3, 4, 5, 6, 7
T_AUDIO, T_TALK_START, T_TALK_END, T_PING = 8, 9, 10, 12
R_AUTH_OK, R_AUTH_FAIL = 0x81, 0x82
R_AUDIO, R_TALK_START, R_TALK_END, R_PONG = 0x88, 0x89, 0x8A, 0x8C


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ uinput
EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
SYN_REPORT = 0
REL_X, REL_Y, REL_HWHEEL, REL_WHEEL = 0x00, 0x01, 0x06, 0x08
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
UI_DEV_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405C5503, 0x5501, 0x5502
BUS_VIRTUAL = 0x06


class UInputDevice:
    def __init__(self, name, keys=(), rels=()):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        self.lock = threading.Lock()
        if keys:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
            for k in keys:
                fcntl.ioctl(self.fd, UI_SET_KEYBIT, k)
        if rels:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_REL)
            for r in rels:
                fcntl.ioctl(self.fd, UI_SET_RELBIT, r)
        setup = struct.pack("HHHH80sI", BUS_VIRTUAL, 0xADEC, 0x0001, 1,
                            name.encode(), 0)
        fcntl.ioctl(self.fd, UI_DEV_SETUP, setup)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)

    def emit(self, events):
        """events: list of (type, code, value); a SYN_REPORT is appended."""
        now = time.time()
        sec, usec = int(now), int((now % 1) * 1e6)
        data = b"".join(struct.pack("llHHi", sec, usec, t, c, v)
                        for t, c, v in events)
        data += struct.pack("llHHi", sec, usec, EV_SYN, SYN_REPORT, 0)
        with self.lock:
            os.write(self.fd, data)

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


# Linux key codes (US layout)
KEY = {
    "esc": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9,
    "9": 10, "0": 11, "-": 12, "=": 13, "backspace": 14, "tab": 15,
    "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22, "i": 23,
    "o": 24, "p": 25, "[": 26, "]": 27, "enter": 28, "ctrl": 29, "a": 30,
    "s": 31, "d": 32, "f": 33, "g": 34, "h": 35, "j": 36, "k": 37, "l": 38,
    ";": 39, "'": 40, "`": 41, "shift": 42, "\\": 43, "z": 44, "x": 45,
    "c": 46, "v": 47, "b": 48, "n": 49, "m": 50, ",": 51, ".": 52, "/": 53,
    "alt": 56, " ": 57, "space": 57, "capslock": 58,
    "f1": 59, "f2": 60, "f3": 61, "f4": 62, "f5": 63, "f6": 64, "f7": 65,
    "f8": 66, "f9": 67, "f10": 68, "f11": 87, "f12": 88,
    "home": 102, "up": 103, "pageup": 104, "left": 105, "right": 106,
    "end": 107, "down": 108, "pagedown": 109, "insert": 110, "delete": 111,
    "mute": 113, "volumedown": 114, "volumeup": 115, "super": 125,
    "nextsong": 163, "playpause": 164, "previoussong": 165,
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
    "|": "\\", ":": ";", '"': "'", "~": "`", "<": ",", ">": ".", "?": "/",
}


class Injector:
    def __init__(self):
        self.mouse = UInputDevice(
            "AirDeck Mouse", keys=(BTN_LEFT, BTN_RIGHT, BTN_MIDDLE),
            rels=(REL_X, REL_Y, REL_WHEEL, REL_HWHEEL))
        self.kbd = UInputDevice("AirDeck Keyboard",
                                keys=sorted(set(KEY.values())))
        self.buttons = {0: BTN_LEFT, 1: BTN_RIGHT, 2: BTN_MIDDLE}
        time.sleep(0.3)  # give the compositor time to pick the devices up

    def move(self, dx, dy):
        self.mouse.emit([(EV_REL, REL_X, dx), (EV_REL, REL_Y, dy)])

    def button(self, b, down):
        self.mouse.emit([(EV_KEY, self.buttons.get(b, BTN_LEFT), 1 if down else 0)])

    def click(self, b):
        self.button(b, True)
        self.button(b, False)

    def scroll(self, v, h):
        ev = []
        if v:
            ev.append((EV_REL, REL_WHEEL, v))
        if h:
            ev.append((EV_REL, REL_HWHEEL, h))
        if ev:
            self.mouse.emit(ev)

    def _tap(self, code, mods=()):
        self.kbd.emit([(EV_KEY, KEY[m], 1) for m in mods] + [(EV_KEY, code, 1)])
        self.kbd.emit([(EV_KEY, code, 0)] + [(EV_KEY, KEY[m], 0) for m in mods])

    def key(self, combo):
        """combo like 'enter', 'ctrl+c', 'alt+tab', 'super'."""
        parts = combo.lower().split("+")
        name, mods = parts[-1], [p for p in parts[:-1] if p in KEY]
        if name in KEY:
            self._tap(KEY[name], mods)

    def text(self, s):
        for ch in s:
            if ch == "\n":
                self._tap(KEY["enter"])
            elif ch == "\t":
                self._tap(KEY["tab"])
            elif ch in KEY and len(ch) == 1 and not ch.isupper():
                self._tap(KEY[ch])
            elif ch.isalpha() and ch.lower() in KEY and ch.isascii():
                self._tap(KEY[ch.lower()], ("shift",))
            elif ch in SHIFTED:
                self._tap(KEY[SHIFTED[ch]], ("shift",))
            # other characters (emoji, non-Latin) are skipped
            time.sleep(0.004)


# ------------------------------------------------------------------- audio
def pw_cmd(mode):
    return ["pw-cat", mode, "--raw", "--format", "s16", "--rate",
            str(SAMPLE_RATE), "--channels", "1", "--latency", "40ms",
            "-P", '{ "node.name": "airdeck", "media.name": "AirDeck talk" }', "-"]


class Speaker:
    """Plays phone voice on the PC while the phone holds its talk button."""

    def __init__(self):
        self.proc = None

    def start(self):
        self.stop()
        self.proc = subprocess.Popen(pw_cmd("-p"), stdin=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL)

    def feed(self, pcm):
        if self.proc is None:
            self.start()
        try:
            self.proc.stdin.write(pcm)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            self.proc = None

    def stop(self):
        if self.proc:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=2)
            except Exception:
                self.proc.kill()
            self.proc = None


# ------------------------------------------------------------------ server
class Server:
    def __init__(self, pin):
        self.pin = pin
        self.inj = Injector()
        self.clients = {}            # sock -> {"name", "lock", "speaker"}
        self.clients_lock = threading.Lock()
        self.pc_talking = False
        self.phone_talking = None    # name of phone currently talking
        self.mic = None

    # -------- sending
    def send(self, sock, ftype, payload=b""):
        info = self.clients.get(sock)
        if not info:
            return
        try:
            with info["lock"]:
                sock.sendall(struct.pack(">BI", ftype, len(payload)) + payload)
        except OSError:
            pass

    def broadcast(self, ftype, payload=b""):
        with self.clients_lock:
            socks = list(self.clients)
        for s in socks:
            self.send(s, ftype, payload)

    # -------- PC push-to-talk (PC mic -> phones)
    def pc_talk_start(self):
        if self.pc_talking:
            return
        self.pc_talking = True
        self.broadcast(R_TALK_START)
        self.mic = subprocess.Popen(pw_cmd("-r"), stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL)
        threading.Thread(target=self._mic_loop, args=(self.mic,),
                         daemon=True).start()
        log("PC talk: started")

    def _mic_loop(self, proc):
        chunk = SAMPLE_RATE * 2 // 25  # 40 ms
        while self.pc_talking and proc.poll() is None:
            data = proc.stdout.read(chunk)
            if not data:
                break
            self.broadcast(R_AUDIO, data)

    def pc_talk_stop(self):
        if not self.pc_talking:
            return
        self.pc_talking = False
        if self.mic:
            self.mic.terminate()
            try:
                self.mic.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.mic.kill()
            self.mic = None
        self.broadcast(R_TALK_END)
        log("PC talk: stopped")

    # -------- per-phone connection
    def handle(self, sock, addr):
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(20)
        f = sock.makefile("rb")
        authed = False
        name = addr[0]
        speaker = Speaker()
        try:
            while True:
                hdr = f.read(5)
                if len(hdr) < 5:
                    break
                ftype, ln = struct.unpack(">BI", hdr)
                if ln > 1_000_000:
                    break
                p = f.read(ln) if ln else b""
                if len(p) < ln:
                    break
                if not authed:
                    if ftype != T_AUTH:
                        break
                    msg = json.loads(p.decode() or "{}")
                    if str(msg.get("pin")) != self.pin:
                        sock.sendall(struct.pack(">BI", R_AUTH_FAIL, 0))
                        log(f"Wrong code from {addr[0]}")
                        break
                    authed = True
                    name = msg.get("name") or addr[0]
                    with self.clients_lock:
                        self.clients[sock] = {"name": name,
                                              "lock": threading.Lock(),
                                              "addr": addr[0]}
                    reply = json.dumps({"host": socket.gethostname()}).encode()
                    self.send(sock, R_AUTH_OK, reply)
                    log(f"Connected: {name} ({addr[0]})")
                    continue
                self.dispatch(sock, ftype, p, speaker, name)
        except (OSError, ValueError, struct.error) as e:
            log(f"Connection error ({name}): {e}")
        finally:
            speaker.stop()
            if self.phone_talking == name:
                self.phone_talking = None
            with self.clients_lock:
                self.clients.pop(sock, None)
            try:
                sock.close()
            except OSError:
                pass
            if authed:
                log(f"Disconnected: {name}")

    def dispatch(self, sock, t, p, speaker, name):
        inj = self.inj
        if t == T_MOVE:
            dx, dy = struct.unpack(">hh", p)
            inj.move(dx, dy)
        elif t == T_BUTTON:
            inj.button(p[0], bool(p[1]))
        elif t == T_CLICK:
            inj.click(p[0])
        elif t == T_SCROLL:
            v, h = struct.unpack(">hh", p)
            inj.scroll(v, h)
        elif t == T_TEXT:
            inj.text(p.decode("utf-8", "ignore"))
        elif t == T_KEY:
            inj.key(p.decode("utf-8", "ignore"))
        elif t == T_TALK_START:
            speaker.start()
            self.phone_talking = name
            log(f"{name} is talking")
        elif t == T_AUDIO:
            speaker.feed(p)
        elif t == T_TALK_END:
            speaker.stop()
            self.phone_talking = None
        elif t == T_PING:
            self.send(sock, R_PONG)

    # -------- listeners
    def serve_tcp(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", TCP_PORT))
        srv.listen(4)
        while True:
            s, addr = srv.accept()
            threading.Thread(target=self.handle, args=(s, addr),
                             daemon=True).start()

    def serve_discovery(self):
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        u.bind(("0.0.0.0", DISCOVERY_PORT))
        reply = json.dumps({"airdeck": 1, "host": socket.gethostname(),
                            "port": TCP_PORT}).encode()
        while True:
            data, addr = u.recvfrom(512)
            if data.startswith(b"AIRDECK?"):
                u.sendto(b"AIRDECK!" + reply, addr)

    def status(self):
        with self.clients_lock:
            phones = [{"name": c["name"], "ip": c["addr"]}
                      for c in self.clients.values()]
        ips = local_ips()
        qr = "airdeck://connect?" + urlencode({
            "ip": ",".join(ips), "port": TCP_PORT, "code": self.pin,
            "host": socket.gethostname()})
        return {"pin": self.pin, "ips": ips, "port": TCP_PORT, "qr": qr,
                "phones": phones, "pcTalking": self.pc_talking,
                "phoneTalking": self.phone_talking,
                "host": socket.gethostname()}


def local_ips():
    ips = set()
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True,
                             text=True).stdout
        for line in out.splitlines():
            parts = line.split()
            ip = parts[3].split("/")[0]
            if not ip.startswith("127."):
                ips.add(ip)
    except Exception:
        pass
    return sorted(ips)


# --------------------------------------------------------------- local page
PAGE = r"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AirDeck</title><link rel="icon" href="/airdeck.svg"><style>
:root{--bg:#0f1115;--card:#181b22;--fg:#e8eaf0;--mut:#9aa0ad;--acc:#5b8cff;--hot:#ff4d5e}
@media (prefers-color-scheme: light){:root{--bg:#f4f5f8;--card:#fff;--fg:#151821;--mut:#5d6472}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.5 system-ui,sans-serif;display:flex;justify-content:center;padding:24px 16px}
main{width:100%;max-width:440px}h1{font-size:22px;margin:0 0 4px}
.mut{color:var(--mut)}.card{background:var(--card);border-radius:16px;padding:18px;margin:14px 0}
.code{font:600 16px ui-monospace,monospace;letter-spacing:2px}
.qrcard{text-align:center}#qr{display:inline-block;background:#fff;padding:14px;border-radius:12px;margin:14px 0}
#qr img,#qr canvas{display:block;width:220px;height:220px}
#talk{width:100%;height:160px;border:0;border-radius:20px;background:var(--acc);
color:#fff;font:600 20px system-ui;cursor:pointer;user-select:none;touch-action:none}
#talk.on{background:var(--hot)}#in{color:var(--acc);font-weight:600;min-height:22px}
</style></head><body><main>
<h1><img src="/airdeck.svg" alt="" width="28" height="28" style="vertical-align:-5px;margin-right:8px">AirDeck</h1><div class="mut" id="host"></div>
<div class="card qrcard"><div class="mut">Open AirDeck on your phone and tap <b>Scan QR</b></div>
<div id="qr"></div>
<div class="mut">Or enter it by hand: address <b id="ips"></b> · code <b class="code" id="pin"></b></div></div>
<div class="card"><div class="mut">Connected phones</div><div id="phones">None</div></div>
<button id="talk">Hold to talk<br><small>(or hold Space)</small></button>
<p id="in"></p>
<script src="/qrcode.min.js"></script><script>
let qrText='',qrObj=null;
function drawQr(t){if(t===qrText||typeof QRCode==='undefined')return;qrText=t;
const el=document.getElementById('qr');el.innerHTML='';
qrObj=new QRCode(el,{text:t,width:220,height:220,correctLevel:QRCode.CorrectLevel.M});}
const b=document.getElementById('talk');let on=false;
function set(v){if(v===on)return;on=v;b.classList.toggle('on',v);
b.innerHTML=v?'Talking…<br><small>release to stop</small>':'Hold to talk<br><small>(or hold Space)</small>';
fetch('/talk/'+(v?'start':'stop'),{method:'POST'}).catch(()=>{});}
b.addEventListener('pointerdown',e=>{b.setPointerCapture(e.pointerId);set(true)});
b.addEventListener('pointerup',()=>set(false));b.addEventListener('pointercancel',()=>set(false));
addEventListener('keydown',e=>{if(e.code==='Space'){e.preventDefault();if(!e.repeat)set(true)}});
addEventListener('keyup',e=>{if(e.code==='Space')set(false)});
addEventListener('blur',()=>set(false));
async function poll(){try{const s=await (await fetch('/status')).json();
pin.textContent=s.pin;drawQr(s.qr);ips.textContent=s.ips.join(', ')||'not on a network';host.textContent=s.host;
phones.textContent=s.phones.length?s.phones.map(p=>p.name+' ('+p.ip+')').join(', '):'None';
document.getElementById('in').textContent=s.phoneTalking?('🔊 '+s.phoneTalking+' is talking'):'';}catch(e){}
setTimeout(poll,700)}poll();
</script></main></body></html>"""


def make_ui_handler(server):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                self._send(200, PAGE.encode(), "text/html; charset=utf-8")
            elif self.path == "/qrcode.min.js":
                with open(os.path.join(HERE, "qrcode.min.js"), "rb") as fh:
                    self._send(200, fh.read(), "application/javascript")
            elif self.path == "/airdeck.svg":
                with open(os.path.join(HERE, "airdeck.svg"), "rb") as fh:
                    self._send(200, fh.read(), "image/svg+xml")
            elif self.path == "/status":
                self._send(200, json.dumps(server.status()).encode(),
                           "application/json")
            else:
                self._send(404, b"not found", "text/plain")

        def do_POST(self):
            if self.path == "/talk/start":
                server.pc_talk_start()
            elif self.path == "/talk/stop":
                server.pc_talk_stop()
            else:
                return self._send(404, b"not found", "text/plain")
            self._send(200, b"ok", "text/plain")
    return H


def load_pin():
    try:
        with open(CONFIG_FILE) as fh:
            pin = json.load(fh).get("pin")
            if pin:
                return str(pin)
    except (OSError, ValueError):
        pass
    pin = f"{random.SystemRandom().randint(0, 999999):06d}"
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w") as fh:
        json.dump({"pin": pin}, fh)
    return pin


def main():
    ap = argparse.ArgumentParser(description="AirDeck PC server")
    ap.add_argument("--no-browser", action="store_true",
                    help="don't open the talk page on start")
    ap.add_argument("--show-code", action="store_true",
                    help="print the connection code and exit")
    args = ap.parse_args()

    pin = load_pin()
    if args.show_code:
        print(pin)
        return

    try:
        ui = ThreadingHTTPServer(("127.0.0.1", UI_PORT), None)
    except OSError:
        print("AirDeck is already running (port in use).", file=sys.stderr)
        if not args.no_browser:
            webbrowser.open(f"http://127.0.0.1:{UI_PORT}/")
        sys.exit(1)

    server = Server(pin)
    ui.RequestHandlerClass = make_ui_handler(server)
    threading.Thread(target=server.serve_tcp, daemon=True).start()
    threading.Thread(target=server.serve_discovery, daemon=True).start()
    threading.Thread(target=ui.serve_forever, daemon=True).start()

    log(f"AirDeck ready. Code {pin}. PC address: {', '.join(local_ips())}")
    log(f"Talk page: http://127.0.0.1:{UI_PORT}/")
    if not args.no_browser:
        webbrowser.open(f"http://127.0.0.1:{UI_PORT}/")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        server.pc_talk_stop()
        server.inj.mouse.close()
        server.inj.kbd.close()


if __name__ == "__main__":
    main()
