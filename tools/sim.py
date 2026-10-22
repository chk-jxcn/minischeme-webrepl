#!/usr/bin/env python3
"""sim.py - the WebREPL's WASM device simulator from the command line.

It runs the real WebREPL page (index.html, the same WASM VM, apps, proxy
and display code as in the browser) in a headless Edge / Chrome / Chromium
driven over the DevTools protocol, so everything works as on the web page,
and takes commands in order:

    python tools/sim.py --app weather --wait 5 --shot weather.png
    python tools/sim.py --eval "(+ 1 2)" --eval "(api-version)"
    python tools/sim.py --config app.carousel=0 --app calendar --press short --wait 2 --shot month.png
    python tools/sim.py --repl            # one command per line on stdin

Commands (repeatable, run in the order given):
  --eval CODE        Scheme in the device VM (as the REPL); prints the result
  --app NAME|FILE    boot an app: a bundled one (apps/<NAME>.msbc), an .msbc
                     image, or Scheme source (.scm, compiled in the page)
  --press KIND       KEY 18: short, long (0.8 s), mid (3.5 s), hold (8 s), or seconds
  --wait SECONDS     let the device run (data fetches, carousel, clock)
  --shot FILE.png    save the LCD canvas
  --config S.K=V     (config-set! "S" "K" "V") in the device's config.ini
  --js EXPR          any JavaScript in the page (awaited); prints the value as JSON
  --log              print the terminal lines written since the last --log
  --repl             read the same commands from stdin ("eval (+ 1 2)", "shot a.png", "quit")

Options:
  --url URL          use a running WebREPL server instead of starting server.py
  --port N           port for the server it starts (default: a free one)
  --profile DIR      browser profile: the simulator's storage (installed apps,
                     config.ini) persists there (default ~/.minischeme-sim)
  --fresh            a new empty profile for this run
  --browser PATH     the browser executable (default: Edge, Chrome or Chromium found)
  --show             a visible browser window instead of headless

Exit status 1 when a command fails (an --eval error, a missing app, ...).
"""

import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRESS_SECONDS = {"short": 0.15, "long": 1.2, "mid": 4.0, "hold": 8.5}
BROWSERS = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge",
]


class SimError(Exception):
    pass


def find_browser(given=None):
    for b in ([given] if given else BROWSERS):
        if b and (os.path.isfile(b) or shutil.which(b)):
            return b if os.path.isfile(b) else shutil.which(b)
    raise SimError("no Edge / Chrome / Chromium found (--browser PATH)")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_http(url, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                return r.read()
        except OSError:
            time.sleep(0.2)
    raise SimError(f"no answer from {url}")


class WebSocket:
    """The little of RFC 6455 the DevTools protocol needs: text frames."""

    def __init__(self, url):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise SimError("DevTools: the browser closed the connection")
            head += chunk
        if b" 101" not in head.split(b"\r\n", 1)[0]:
            raise SimError("DevTools: no WebSocket upgrade")
        self.buf = head.split(b"\r\n\r\n", 1)[1]

    def send(self, text):
        data = text.encode("utf-8")
        n = len(data)
        head = bytearray([0x81])
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(bytes(head) + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(data)))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                raise SimError("DevTools: connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        message = b""
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(n)
            op = b0 & 0x0F
            if op == 0x8:
                raise SimError("DevTools: connection closed")
            if op in (0x9, 0xA):
                continue
            message += payload
            if b0 & 0x80:
                return message.decode("utf-8", "replace")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Page:
    """One page target: Runtime.evaluate with awaited promises."""

    def __init__(self, ws_url):
        self.ws = WebSocket(ws_url)
        self.next_id = 0

    def call(self, method, **params):
        self.next_id += 1
        mid = self.next_id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise SimError(f"DevTools {method}: {msg['error'].get('message')}")
                return msg.get("result", {})

    def js(self, expr, timeout=120):
        r = self.call("Runtime.evaluate", expression=expr, awaitPromise=True, returnByValue=True,
                      timeout=timeout * 1000)
        if "exceptionDetails" in r:
            d = r["exceptionDetails"]
            text = (d.get("exception") or {}).get("description") or d.get("text") or "JavaScript error"
            raise SimError(text.splitlines()[0])
        return (r.get("result") or {}).get("value")


class Simulator:
    def __init__(self, url=None, port=None, profile=None, fresh=False, browser=None, show=False):
        self.server = self.browser = None
        self.tmp_profile = self.tmp_data = None
        try:
            if url:
                self.base = url.rstrip("/")
            else:
                port = port or free_port()
                env = dict(os.environ)
                env.setdefault("MINISCHEME_ADMIN_PASSWORD", "sim-local-admin")
                if fresh:   # the server's database and config.ini too: nothing of this run is kept
                    self.tmp_data = tempfile.mkdtemp(prefix="minischeme-sim-data-")
                    env["MINISCHEME_DATA_DIR"] = self.tmp_data
                self.server = subprocess.Popen([sys.executable, "server.py", "--no-tray", "--port", str(port)],
                                               cwd=ROOT, env=env, stdout=subprocess.DEVNULL,
                                               stderr=subprocess.DEVNULL)
                self.base = f"http://127.0.0.1:{port}"
            wait_http(self.base + "/", 30)
            if fresh:
                self.tmp_profile = profile = tempfile.mkdtemp(prefix="minischeme-sim-")
            profile = profile or os.path.join(os.path.expanduser("~"), ".minischeme-sim")
            os.makedirs(profile, exist_ok=True)
            dport = free_port()
            cmd = [find_browser(browser), f"--remote-debugging-port={dport}", f"--user-data-dir={profile}",
                   "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                   "--window-size=1500,1000", "--autoplay-policy=no-user-gesture-required"]
            if not show:
                cmd.append("--headless=new")
            self.browser = subprocess.Popen(cmd + [self.base + "/"], stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL)
            ws = None
            end = time.time() + 30
            while time.time() < end and not ws:
                try:
                    targets = json.loads(wait_http(f"http://127.0.0.1:{dport}/json", 5))
                    ws = next((t["webSocketDebuggerUrl"] for t in targets
                               if t.get("type") == "page" and t.get("url", "").startswith(self.base)), None)
                except (SimError, ValueError):
                    pass
                if not ws:
                    time.sleep(0.3)
            if not ws:
                raise SimError("the browser did not open the WebREPL page")
            self.page = Page(ws)
            self._wait_ready()
        except BaseException:
            self.close()
            raise

    def _wait_ready(self):
        end = time.time() + 60
        while time.time() < end:
            try:
                if self.page.js("typeof wasmInstance !== 'undefined' && !!wasmInstance && "
                                "typeof evalLocalWasm === 'function'"):
                    time.sleep(1.5)   # the boot app starts
                    self.page.js("window.__simLog = document.querySelectorAll('#terminal .term-line').length")
                    return
            except SimError:
                pass
            time.sleep(0.3)
        raise SimError("the WASM device did not start")

    # ---- commands ---------------------------------------------------------
    def eval(self, code):
        r = self.page.js(f"evalLocalWasm({json.dumps(code)})")
        if not r or not r.get("success"):
            raise SimError((r or {}).get("result") or "eval failed")
        return r.get("result", "")

    def app(self, name):
        if os.path.isfile(name) and name.lower().endswith(".scm"):
            src = open(name, encoding="utf-8").read()
            expr = (f"(() => {{ const c = compileWithWasm({json.dumps(src)});"
                    f" if (!c.success) throw new Error('compile: ' + c.error);"
                    f" const r = startAppOnWasmDevice(c.bytes);"
                    f" if (String(r).startsWith('Error:')) throw new Error(r); return r; }})()")
        elif os.path.isfile(name):
            b64 = base64.b64encode(open(name, "rb").read()).decode()
            expr = (f"(() => {{ const b = Uint8Array.from(atob('{b64}'), (c) => c.charCodeAt(0));"
                    f" const r = startAppOnWasmDevice(b);"
                    f" if (String(r).startsWith('Error:')) throw new Error(r); return r; }})()")
        else:
            path = "apps/" + urllib.parse.quote(name) + (".msbc" if not name.endswith(".msbc") else "")
            expr = (f"(async () => {{ const res = await fetch('{path}', {{cache: 'no-store'}});"
                    f" if (!res.ok) throw new Error('no app {name} ({path}: HTTP ' + res.status + ')');"
                    f" const r = startAppOnWasmDevice(new Uint8Array(await res.arrayBuffer()));"
                    f" if (String(r).startsWith('Error:')) throw new Error(r); return r; }})()")
        return self.page.js(expr)

    def press(self, kind):
        secs = PRESS_SECONDS.get(kind)
        if secs is None:
            try:
                secs = float(kind)
            except ValueError:
                raise SimError(f"press: short, long, mid, hold or seconds, not {kind!r}")
        ms = int(secs * 1000)
        self.page.js(f"(async () => {{ k18Press(); await new Promise((r) => setTimeout(r, {ms}));"
                     f" k18Release(); await new Promise((r) => setTimeout(r, 150)); }})()", timeout=int(secs) + 30)
        return f"pressed {secs:g} s"

    def wait(self, secs):
        time.sleep(float(secs))
        return ""

    def shot(self, path):
        url = self.page.js("document.getElementById('virtual-lcd').toDataURL('image/png')")
        data = base64.b64decode(url.split(",", 1)[1])
        with open(path, "wb") as f:
            f.write(data)
        w, h = struct.unpack(">II", data[16:24])
        return f"saved {path} ({w}x{h})"

    def config(self, assignment):
        if "=" not in assignment or "." not in assignment.split("=", 1)[0]:
            raise SimError("config: SECTION.KEY=VALUE")
        key, value = assignment.split("=", 1)
        section, k = key.split(".", 1)
        return self.eval(f"(config-set! {json.dumps(section)} {json.dumps(k)} {json.dumps(value)})")

    def js(self, expr):
        return json.dumps(self.page.js(expr), ensure_ascii=False)

    def log(self, _=None):
        lines = self.page.js("(() => { const all = [...document.querySelectorAll('#terminal .term-line')];"
                             " const out = all.slice(window.__simLog || 0).map((e) => e.textContent);"
                             " window.__simLog = all.length; return out; })()")
        return "\n".join(lines)

    def run(self, cmd, arg):
        fn = {"eval": self.eval, "app": self.app, "press": self.press, "wait": self.wait, "shot": self.shot,
              "config": self.config, "js": self.js, "log": self.log}.get(cmd)
        if not fn:
            raise SimError(f"unknown command {cmd!r}")
        return fn(arg)

    def close(self):
        for p in (self.browser, self.server):
            if p and p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
        for tmp in (self.tmp_profile, self.tmp_data):
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)


def parse_args(argv):
    opts = {"url": None, "port": None, "profile": None, "fresh": False, "browser": None, "show": False}
    commands, i = [], 0
    takes = {"--eval", "--app", "--press", "--wait", "--shot", "--config", "--js"}
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        if a in takes:
            if i + 1 >= len(argv):
                raise SimError(f"{a} needs a value")
            commands.append((a[2:], argv[i + 1]))
            i += 2
        elif a in ("--log", "--repl"):
            commands.append((a[2:], None))
            i += 1
        elif a in ("--url", "--port", "--profile", "--browser"):
            if i + 1 >= len(argv):
                raise SimError(f"{a} needs a value")
            opts[a[2:]] = int(argv[i + 1]) if a == "--port" else argv[i + 1]
            i += 2
        elif a in ("--fresh", "--show"):
            opts[a[2:]] = True
            i += 1
        else:
            raise SimError(f"unknown argument {a!r} (--help)")
    return opts, commands


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):   # the terminal's lines are UTF-8 (emoji, Chinese)
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    try:
        opts, commands = parse_args(sys.argv[1:] if argv is None else argv)
    except SimError as e:
        print(f"sim: {e}", file=sys.stderr)
        return 2
    if not commands:
        print(__doc__)
        return 0
    failed = False
    try:
        sim = Simulator(**opts)
    except SimError as e:
        print(f"sim: {e}", file=sys.stderr)
        return 1
    try:
        for cmd, arg in commands:
            if cmd == "repl":
                for line in sys.stdin:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if line in ("quit", "exit"):
                        break
                    c, _, a = line.partition(" ")
                    try:
                        out = sim.run(c, a.strip() or None)
                        print(out if out is not None else "", flush=True)
                    except SimError as e:
                        print(f"error: {e}", flush=True)
                        failed = True
                continue
            try:
                out = sim.run(cmd, arg)
                if out:
                    print(out, flush=True)
            except SimError as e:
                print(f"sim: {cmd} {arg or ''}: {e}", file=sys.stderr)
                failed = True
                break
    finally:
        sim.close()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
