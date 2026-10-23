"""Color schemes (apps/lib/gui.scm, API 1.8 theme-css) on the simulator
(tools/sim.py; skipped without Edge / Chrome / Chromium): the built-in day
and night schemes, the cascade (the app's theme.css, the system's, the app's
defaults, the built-in scheme, the alias's category), the mode by the clock
and by the light sensor, and a changed file taking effect."""
import json
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import sim  # noqa: E402


def _browser():
    try:
        return sim.find_browser()
    except sim.SimError:
        return None


# files written into the simulator's file system before the app boots
WRITE = r"""(() => {
  const ex = wasmInstance.exports, te = new TextEncoder();
  const put = (path, bytes) => {
    const enc = te.encode(path + '\0'), p = ex.wasm_alloc_buffer(enc.length);
    new Uint8Array(wasmMemory.buffer).set(enc, p);
    const b = ex.wasm_alloc_buffer(bytes.length || 1);
    new Uint8Array(wasmMemory.buffer).set(bytes, b);
    const e = ex.wasm_fs_write(p, b, bytes.length);
    ex.wasm_free_buffer(b); ex.wasm_free_buffer(p); return e;
  };
  return Object.entries(FILES).map(([p, t]) => put(p, te.encode(t))).every((x) => x === 0);
})()"""


def run_sim(args, timeout=300):
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sim.py"), "--fresh"] + args,
                       capture_output=True, encoding="utf-8", errors="replace", timeout=timeout)
    return r, [l for l in r.stdout.splitlines() if not l.startswith(("saved ", "pressed "))]


def rgb(h):
    """#rrggbb -> the RGB565 value gui-rgb gives"""
    r, g, b = int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


SYS_CSS = """/* the system's */
night { titlebar_bg: #400000; my_gold: #ffcc33; accent_fg: my_gold; card_border: rgb(16, 32, 48); }
day { titlebar_bg: #fedcba; }
* { seg_on_fg: #0f0; }
sakura { bg: #fff0f5; }
"""
APP_CSS = "night { titlebar_bg: #004000; }"

# (name, expression, expected): run in order on one device, theme = night
CHECKS = [
    ("night by config", "theme-mode", '"night"'),
    ("the app's theme.css wins over the system's", '(theme-color "titlebar_bg")', str(rgb("#004000"))),
    ("the theme-* colors follow", "theme-card-hdr", str(rgb("#004000"))),
    ("an alias of an alias", '(theme-color "accent_fg")', str(rgb("#ffcc33"))),
    ("rgb()", '(theme-color "card_border")', str(rgb("#102030"))),
    ("#rgb in the * block", '(theme-color "seg_on_fg")', str(rgb("#00ff00"))),
    ("the built-in night scheme", '(theme-color "text_fg")', str(rgb("#e6ecf3"))),
    ("an unknown alias: its category", '(theme-color "my_panel_bg")', str(rgb("#0b1118"))),
    ("a literal passes", '(theme-color "#123456")', str(rgb("#123456"))),
    ("a number passes", "(theme-color 1234)", "1234"),
    ("the app's defaults come after the files",
     '(begin (theme-defaults! "night" (list (cons "titlebar_bg" "#111111") (cons "photo_bg" "#000000"))) '
     '(list (theme-color "titlebar_bg") (theme-color "photo_bg")))', f"({rgb('#004000')} 0)"),
    ("day: the system's day block", '(begin (set! theme-mode "day") (theme-apply!) (theme-color "titlebar_bg"))',
     str(rgb("#fedcba"))),
    ("day: the built-in day scheme", '(theme-color "text_fg")', str(rgb("#17202b"))),
    ("a scheme of one's own for the day",
     '(begin (config-set! "theme" "theme_day" "sakura") (theme-apply!) (list theme-scheme (theme-color "bg") (theme-color "text_fg")))',
     f'("sakura" {rgb("#fff0f5")} {rgb("#17202b")})'),
    ("by the clock", '(begin (config-set! "theme" "theme" "auto") (config-set! "theme" "theme_switch" "time") '
     '(config-set! "theme" "theme_day_start" "00:00") (config-set! "theme" "theme_night_start" "00:00") (theme-pick-mode))',
     '"night"'),
    ("by the light: bright", '(begin (config-set! "theme" "theme_switch" "light") (config-set! "theme" "theme_light_day" "100") '
     '(theme-pick-mode))', '"day"'),
    ("by the light: dark", '(begin (config-set! "theme" "theme_light_day" "900") (config-set! "theme" "theme_light_night" "600") '
     '(theme-pick-mode))', '"night"'),
    ("a changed file is noticed within 10 ticks",
     '(begin (fs-write "theme.css" "night { titlebar_bg: #000040; }") (config-set! "theme" "theme" "night") '
     '(let loop ((i 0) (c #f)) (if (< i 10) (loop (+ i 1) (or (theme-tick!) c)) (list c (theme-color "titlebar_bg")))))',
     f"(#t {rgb('#000040')})"),
]


@unittest.skipUnless(_browser(), "no Edge / Chrome / Chromium")
class TestTheme(unittest.TestCase):
    def test_cascade_and_mode(self):
        files = {"/spiffs/theme.css": SYS_CSS, "/spiffs/apps/app/theme.css": APP_CSS}
        args = ["--wait", "1", "--js", WRITE.replace("FILES", json.dumps(files)), "--config", "theme.theme=night",
                "--app", "calendar", "--wait", "4"]
        for _, expr, _ in CHECKS:
            args += ["--eval", expr]
        r, lines = run_sim(args)
        self.assertEqual(r.returncode, 0, r.stderr)
        for (name, _, want), got in zip(CHECKS, lines[-len(CHECKS):]):
            with self.subTest(check=name):
                self.assertEqual(got, want)

    def test_light_sensor_default(self):
        # nothing set: auto by the light sensor; the simulator's light is 500 (day)
        r, lines = run_sim(["--app", "calendar", "--wait", "4", "--eval", "(list (light-lux) theme-mode (theme-css))"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(lines[-1], '(500 "day" #f)')


if __name__ == "__main__":
    unittest.main()
