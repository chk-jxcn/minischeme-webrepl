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
