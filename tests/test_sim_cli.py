"""tools/sim.py: the WebREPL simulator from the command line (skipped without
Edge / Chrome / Chromium)."""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import sim  # noqa: E402


def _browser():
    try:
        return sim.find_browser()
    except sim.SimError:
        return None


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
