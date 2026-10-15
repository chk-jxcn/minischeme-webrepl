#!/usr/bin/env python3
"""
MiniScheme WASM WebREPL Local Server & ESP32 Node Simulator
"""

import http.server
import socketserver
import subprocess
import json
import os
import sys
import urllib.parse
import urllib.request

PORT = int(os.environ.get("WEBREPL_PORT", "8080"))
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
import threading
import base64

TOOLS_DIR = os.path.join(os.path.dirname(BASE_DIR), "tools")
_font_lock = threading.Lock()


def font_engine():
    """tools/make_font.py: the same font generator as the command line"""
    if TOOLS_DIR not in sys.path:
        sys.path.insert(0, TOOLS_DIR)
    import make_font
    return make_font


def font_faces():
    with _font_lock:
        faces = font_engine().list_faces()
    return {"success": True, "faces": [{k: f[k] for k in ("id", "family", "family_zh", "file", "cjk", "glyphs")}
                                       for f in faces]}


def font_make(req):
    """{face, size, presets, chars, name, y_offset, spacing, bpp} -> MFNT (base64) + stats"""
    mf = font_engine()
    with _font_lock:
        faces = {f["file"].lower(): f["path"] for f in mf.list_faces()}
    face = str(req.get("face", ""))
    face = faces.get(face.lower(), face)  # installed file names map to their paths
    if os.path.isabs(face) and face not in faces.values():
        raise mf.FontError("unknown font file")
    chars = mf.collect_chars(req.get("presets") or [], str(req.get("chars") or ""))
    y = req.get("y_offset")
    data, info = mf.build_font(face, int(req.get("size", 16)), chars, (req.get("name") or None),
                               None if y in (None, "") else int(y), str(req.get("spacing") or "font"),
                               int(req.get("bpp") or 1))
    info["face"] = os.path.basename(info["face"])
    return {"success": True, **info, "mfnt": base64.b64encode(data).decode("ascii")}

SIM_EXE = os.path.join(BASE_DIR, "sim_esp32_v2.exe") if os.path.exists(os.path.join(BASE_DIR, "sim_esp32_v2.exe")) else os.path.join(BASE_DIR, "sim_esp32.exe")

class PersistentVM:
    def __init__(self):
        self.proc = None
        self.lock = threading.Lock()
        self._start()

    def _start(self):
        try:
            self.proc = subprocess.Popen(
                [SIM_EXE],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                cwd=BASE_DIR,
                # no console window when the server itself runs without one (server_tray.pyw)
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except Exception as e:
            print(f"[Error] Failed to start sim_esp32.exe: {e}")
            self.proc = None

    def execute_hex(self, hex_str):
        if not hex_str or not hex_str.strip():
            return {"success": False, "error": "empty bytecode"}
        with self.lock:
            if not self.proc or self.proc.poll() is not None:
                self._start()
            if not self.proc:
                return {"success": False, "error": "VM process unavailable"}

            try:
                self.proc.stdin.write(hex_str.strip() + "\n")
                self.proc.stdin.flush()
                line = self.proc.stdout.readline()
                if not line:
                    return {"success": False, "error": "Device simulator exited unexpectedly"}
                return json.loads(line)
            except Exception as e:
                return {"success": False, "error": str(e)}

vm_node = PersistentVM()

_app_proxy = None


def app_proxy():
    """tools/app_proxy.py, imported on first use"""
    global _app_proxy
    if _app_proxy is None:
        sys.path.insert(0, os.path.join(os.path.dirname(BASE_DIR), "tools"))
        import app_proxy as mod
        _app_proxy = mod
    return _app_proxy


class WebReplHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=BASE_DIR, **kwargs)

    def do_GET(self):
        # /api/fetch?url=http://host/....json: JSON feeds (json-feed-start) on
        # the simulated device; most servers send no CORS headers, so the page
        # asks us. Plain-HTTP .json URLs are forwarded; app proxy URLs
        # (http://<pc>:8087/app/...) are answered here by tools/app_proxy.py,
        # so the simulator runs the apps without that process.
        if self.path.startswith("/api/fetch?") or self.path.startswith("/api/lhm?"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            url = (query.get("url") or [""])[0]
            parsed = urllib.parse.urlparse(url)
            # (and the app market, /market/: index.json and app images)
            if parsed.scheme == "http" and (parsed.path.startswith("/app/") or parsed.path == "/fetch"
                                            or parsed.path.startswith("/market/")):
                status, ctype, body = app_proxy().handle(parsed.path + ("?" + parsed.query if parsed.query else ""))
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            image = parsed.path.endswith((".msbc", ".fasl"))   # app images of another market
            if parsed.scheme != "http" or not (parsed.path.endswith(".json") or image):
                self.send_error(400, "url must be http://<host>/<path>.json, an app image or an app proxy URL (/app/...)")
                return
            try:
                with urllib.request.urlopen(url, timeout=3) as resp:
                    body = resp.read(512 * 1024)
                status = 200
            except Exception as e:
                body = f"{url} unreachable: {e}".encode("utf-8")
                status = 502
            self.send_response(status)
            self.send_header("Content-Type", ("application/octet-stream" if image else "application/json")
                             if status == 200 else "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/api/font/faces":
            self._json_reply(self._font_call(font_faces))
            return
        super().do_GET()

    def _font_call(self, fn, *args):
        try:
            return fn(*args)
        except ImportError as e:
            return {"success": False, "error": f"font generator needs Pillow and fontTools: {e}"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def _json_reply(self, res):
        body = json.dumps(res, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == "/api/font/make":
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            try:
                req = json.loads(body.decode("utf-8"))
            except ValueError:
                req = None
            self._json_reply(self._font_call(font_make, req) if isinstance(req, dict)
                             else {"success": False, "error": "expected a JSON object"})
            return
        if self.path == "/api/execute_bytecode":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8")
            try:
                req_data = json.loads(body)
                hex_str = req_data.get("bytecode_hex", "")
                res = vm_node.execute_hex(hex_str)
            except Exception as e:
                res = {"success": False, "error": f"Invalid request: {e}"}

            res_bytes = json.dumps(res).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(res_bytes)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(res_bytes)
        else:
            self.send_error(404, "Endpoint not found")

    def end_headers(self):
        # Enable proper MIME type and CORS
        if self.path.endswith(".wasm"):
            self.send_header("Content-Type", "application/wasm")
        elif self.path.endswith((".fasl", ".msbc")):
            self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

def main():
    import argparse
    parser = argparse.ArgumentParser(description="MiniScheme WASM WebREPL Server")
    parser.add_argument("--port", type=int, default=PORT, help="Port to listen on")
    parser.add_argument("--with-proxy", action="store_true", help="Also start local App Proxy and Protocol Converter")
    parser.add_argument("--proxy-port", type=int, default=8087, help="App Proxy port")
    args = parser.parse_args()

    proxy_proc = None
    if args.with_proxy:
        proxy_script = os.path.join(os.path.dirname(BASE_DIR), "minischeme-proxy", "app_proxy.py")
        if os.path.exists(proxy_script):
            print(f"[*] Starting local App Proxy on port {args.proxy_port}...")
            proxy_proc = subprocess.Popen([sys.executable, proxy_script, "--mode", "local", "--port", str(args.proxy_port)])
        else:
            print(f"[!] Proxy script not found at {proxy_script}")

    os.chdir(BASE_DIR)
    with http.server.ThreadingHTTPServer(("", args.port), WebReplHandler) as httpd:
        print("=" * 60)
        print("  MiniScheme WASM WebREPL Local Server Started!")
        print(f"  URL: http://localhost:{args.port}")
        if args.with_proxy:
            print(f"  Local App Proxy: http://localhost:{args.proxy_port}")
        print("  Architecture: Browser WASM Compiler -> Binary Bytecode -> ESP32 Simulator")
        print("=" * 60)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down server...")
        finally:
            if proxy_proc:
                proxy_proc.terminate()

if __name__ == "__main__":
    main()
