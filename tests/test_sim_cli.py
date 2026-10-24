"""tools/sim.py: the WebREPL simulator from the command line (skipped without
Edge / Chrome / Chromium)."""
import http.server
import os
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import sim  # noqa: E402


def _browser():
    try:
        return sim.find_browser()
    except sim.SimError:
        return None


class _FakeFontServer(http.server.BaseHTTPRequestHandler):
    """A font server (minischeme-proxy font_server.py) in miniature: every
    code point a 20 px wide filled glyph, U+10FFFD absent"""
    asked = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        cps = [int(c, 16) for c in qs["cps"][0].split(",")]
        _FakeFontServer.asked.append((qs["face"][0], qs["size"][0], cps))
        body = b"MGLY" + struct.pack("<BBBBIHH", 1, 16, 1, 0, 0x1234, len(cps), 0)
        for cp in cps:
            body += struct.pack("<IBB", cp, 0, 0) if cp == 0x10FFFD else struct.pack("<IBB", cp, 20, 3) + b"\xff" * 48
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@unittest.skipUnless(_browser(), "no Edge / Chrome / Chromium")
class TestSimCli(unittest.TestCase):
    def test_eval_app_press_shot(self):
        with tempfile.TemporaryDirectory() as tmp:
            shot = os.path.join(tmp, "cal.png")
            r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh",
                                "--eval", "(+ 1 2)", "--eval", "(api-version)",
                                "--app", "calendar", "--wait", "2", "--press", "short", "--wait", "1",
                                "--shot", shot, "--js", "app_npages_probe = 1"],
                               capture_output=True, encoding="utf-8", errors="replace", timeout=180)
            self.assertEqual(r.returncode, 0, r.stderr)
            lines = r.stdout.splitlines()
            self.assertEqual(lines[0], "3")
            self.assertTrue(lines[1].startswith('"1.'), lines[1])
            with open(shot, "rb") as f:
                head = f.read(24)
            self.assertEqual(head[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", head[16:24]), (320, 480))

    def test_scheduled_launch(self):
        # calendar is the boot app; medicine (schedule.ini 08:00) starts at 08:00,
        # takes one press per medicine due then and returns to calendar
        install = r"""(async () => {
  const ex = wasmInstance.exports, te = new TextEncoder();
  const put = (path, bytes) => {
    const enc = te.encode(path + '\0'), p = ex.wasm_alloc_buffer(enc.length);
    new Uint8Array(wasmMemory.buffer).set(enc, p);
    const b = ex.wasm_alloc_buffer(bytes.length || 1);
    new Uint8Array(wasmMemory.buffer).set(bytes, b);
    const e = ex.wasm_fs_write(p, b, bytes.length);
    ex.wasm_free_buffer(b); ex.wasm_free_buffer(p); return e;
  };
  const get = async (u) => new Uint8Array(await (await fetch(u)).arrayBuffer());
  return [put('/spiffs/apps/medicine/app.msbc', await get('apps/medicine.msbc')),
          put('/spiffs/apps/calendar/app.msbc', await get('apps/calendar.msbc')),
          put('/spiffs/apps/medicine/schedule.ini', te.encode('[schedule]\ntimes = 08:00, 12:30\n')),
          put('/spiffs/apps/medicine/meds.txt', te.encode('1|A|1|1|0|0\n2|B|2|1,2|0|0\n3|C|1|2|0|0'))];
})()"""
        state = '(list (cadr (app-info)) (app-scheduled))'
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh", "--wait", "1",
                            "--js", install, "--config", "system.boot_app=apps/calendar/app.msbc",
                            "--js", 'bootWasmDevice("test")', "--wait", "2", "--eval", state,
                            "--js", "wasmInstance.exports.wasm_schedule_fire(8, 0)", "--wait", "3",
                            "--eval", state, "--eval", "(list med-due-total (map (lambda (x) (med-name (car x))) med-due))",
                            "--press", "short", "--wait", "1", "--press", "short", "--wait", "6",
                            "--eval", state],
                           capture_output=True, encoding="utf-8", errors="replace", timeout=240)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], "[0, 0, 0, 0]")
        self.assertIn('("calendar" #f)', lines)
        self.assertIn('("medicine" "08:00")', lines)
        self.assertIn('(2 ("A" "B"))', lines)
        self.assertEqual(lines[-1], '("calendar" #f)')

    def test_fs_download(self):
        # (fs-download url path): the page fetches through server.py and the
        # VM writes the file; one at a time; a missing file is an error outcome
        size = os.path.getsize(os.path.join(ROOT, "apps", "index.json"))
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh", "--wait", "3",
                            "--eval", '(fs-download "http://proxy.local/apps/index.json" "/spiffs/dl.json")',
                            "--eval", '(fs-download "http://proxy.local/apps/index.json" "/spiffs/dl2.json")',
                            "--wait", "3",
                            "--eval", "(let ((s (fs-download-status))) (list (cdr (assq 'state s)) (cdr (assq 'bytes s))))",
                            "--eval", '(string-length (fs-read "/spiffs/dl.json"))',
                            "--eval", '(fs-download "http://proxy.local/no/such/file" "/spiffs/x.bin")',
                            "--wait", "3",
                            "--eval", "(cdr (assq 'state (fs-download-status)))"],
                           capture_output=True, encoding="utf-8", errors="replace", timeout=180)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[:2], ["#t", "#f"])
        self.assertEqual(lines[2], f"(done {size})")
        self.assertEqual(lines[3], str(size))
        self.assertEqual(lines[4:6], ["#t", "error"])

    def test_fs_download_on_done(self):
        # (fs-download url path on-done): the main loop calls (on-done ok path) once
        # the download ended, done or failed; on-done must be a procedure
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh", "--wait", "3",
                            "--eval", "(define dl-seen '())",
                            "--eval", "(define (dl-done ok path) (set! dl-seen (cons (list ok path) dl-seen)))",
                            "--eval", '(fs-download "http://proxy.local/apps/index.json" "/spiffs/dl.json" dl-done)',
                            "--wait", "3",
                            "--eval", '(fs-download "http://proxy.local/no/such/file" "/spiffs/x.bin" dl-done)',
                            "--wait", "3",
                            "--eval", "dl-seen",
                            "--eval", '(fs-download "http://proxy.local/apps/index.json" "/spiffs/y.json" 5)'],
                           capture_output=True, encoding="utf-8", errors="replace", timeout=180)
        self.assertEqual(r.returncode, 1, r.stdout)   # the last --eval is an error
        lines = r.stdout.splitlines()
        self.assertEqual(lines[2:5], ["#t", "#t", '((#f "/spiffs/x.bin") (#t "/spiffs/dl.json"))'])
        self.assertIn("on-done must be a procedure", r.stdout + r.stderr)

    def test_install_and_webshot(self):
        # --install: the app's folder as the market writes it, booted; its web page
        # then opens (--webshot), and the proxy URL it hands to the browser is the
        # page's own server
        with tempfile.TemporaryDirectory() as tmp:
            shot = os.path.join(tmp, "web.png")
            r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh",
                                "--install", "memo", "--wait", "3", "--webshot", shot,
                                "--eval", "(app-proxy)", "--js", "window.location.origin"],
                               capture_output=True, encoding="utf-8", errors="replace", timeout=180)
            self.assertEqual(r.returncode, 0, r.stderr)
            lines = r.stdout.splitlines()
            self.assertTrue(lines[0].startswith("installed memo"), lines[0])
            self.assertIn("web.png", lines[1])
            self.assertEqual(lines[2], lines[3])          # "http://127.0.0.1:PORT" both
            with open(shot, "rb") as f:
                head = f.read(24)
            self.assertEqual(head[:4], b"\x89PNG")
            self.assertGreater(struct.unpack(">II", head[16:24])[0], 300)

    def test_font_server(self):
        # a glyph no font has is asked for once, drawn when it arrives; one the
        # server lacks is kept as absent; off: never asked
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _FakeFontServer)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{srv.server_address[1]}"
        _FakeFontServer.asked.clear()
        try:
            r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh",
                                "--config", f"fonts.font_server={url}", "--js", "bootWasmDevice('font server')",
                                "--wait", "3",
                                "--eval", '(gui-text-width "\U0001F600\uD55C" 0)', "--wait", "2",
                                "--eval", '(gui-text-width "\U0001F600\uD55C" 0)',
                                "--eval", '(gui-text-width "\U0010FFFD" 0)', "--wait", "2",
                                "--eval", "(let ((s (font-server))) (list (cdr (assq 'state s)) (cdr (assq 'absent s))))",
                                "--config", "fonts.font_server_on=0", "--js", "wasmInstance.exports.wasm_fontnet_reconfigure()",
                                "--eval", '(gui-text-width "\U0001F601" 0)', "--wait", "2",
                                "--eval", "(cdr (assq 'state (font-server)))"],
                               capture_output=True, encoding="utf-8", errors="replace", timeout=180)
        finally:
            srv.shutdown()
            srv.server_close()
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = [l for l in r.stdout.splitlines() if l and l not in ("null", "#t")]
        self.assertEqual(lines[0], "32", r.stdout)       # before: the box width of both
        self.assertEqual(lines[1], "40")       # the server's 20 px glyphs
        self.assertEqual(lines[3], "(idle 1)")
        self.assertEqual(lines[4], "16")       # off: not asked for
        self.assertEqual(lines[5], "off")
        asked = [cp for _, _, cps in _FakeFontServer.asked for cp in cps]
        self.assertEqual(sorted(asked), [0xD55C, 0x1F600, 0x10FFFD])
        self.assertEqual(_FakeFontServer.asked[0][:2], ("simsun", "16"))

    def test_errors_fail(self):
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh",
                            "--eval", "(car 1)"], capture_output=True, encoding="utf-8", errors="replace",
                           timeout=180)
        self.assertEqual(r.returncode, 1)
        self.assertIn("car", r.stderr)

    def test_arguments(self):
        opts, cmds = sim.parse_args(["--fresh", "--app", "weather", "--press", "long", "--log"])
        self.assertTrue(opts["fresh"])
        self.assertEqual(cmds, [("app", "weather"), ("press", "long"), ("log", None)])
        with self.assertRaises(sim.SimError):
            sim.parse_args(["--wait"])


if __name__ == "__main__":
    unittest.main()
