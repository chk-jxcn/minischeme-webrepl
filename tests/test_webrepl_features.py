"""
MiniScheme WebREPL Comprehensive Automated Test Suite
Tests every feature of the WebREPL interface, WASM compiler,
Scheme editor, firmware flasher, device setup wizard, app market,
and server integration.
"""

import http.client
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import unittest

import shutil

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPS_DIR = os.path.join(ROOT_DIR, "apps")
TEST_PORT = 8095


def find_browser_executable():
    candidates = [
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium-browser",
    ]
    for c in candidates:
        if os.path.isabs(c) and os.path.exists(c):
            return c
        found = shutil.which(c)
        if found:
            return found
    return None


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]


class WebReplServerFixture:
    def __init__(self, port, with_proxy=False):
        self.port = port
        self.with_proxy = with_proxy
        self.proc = None

    def start(self):
        cmd = [sys.executable, "server.py", "--port", str(self.port)]
        if self.with_proxy:
            cmd.extend(["--with-proxy", "--proxy-port", str(self.port + 1)])
        self.proc = subprocess.Popen(
            cmd,
            cwd=ROOT_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        # Wait until server accepts connections
        t0 = time.time()
        while time.time() - t0 < 5.0:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=1)
                conn.request("GET", "/")
                res = conn.getresponse()
                if res.status == 200:
                    return
            except Exception:
                time.sleep(0.1)
        raise RuntimeError("WebREPL server failed to start within 5s")

    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class TestWebReplFeatures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = find_free_port()
        cls.server = WebReplServerFixture(cls.port)
        cls.server.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.stop()

    def test_01_index_html_assets(self):
        """Verify index.html serves with workspace tabs, hidden editor view, and no hex/disasm/fixed-pages"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        body = res.read().decode("utf-8")
        self.assertIn("tab-btn-repl", body, "REPL workspace tab missing")
        self.assertIn("tab-btn-editor", body, "Editor workspace tab missing")
        self.assertIn('id="editor-dialog" class="ws-view editor-workspace-view" hidden', body, "Editor must be hidden by default")
        self.assertIn("flasher-dialog", body, "Firmware Flasher dialog missing")
        self.assertIn("btn-device-setup", body, "Device Setup button missing")
        self.assertIn("btn-link-device-setup", body, "Link bar Device Setup button next to Connect button missing")
        self.assertIn("btn-scheme-editor", body, "Editor button missing")
        self.assertIn("btn-firmware-flasher", body, "Flasher button missing")
        self.assertIn("editor_flasher.js", body, "editor_flasher.js script missing")
        self.assertIn("device_setup.js", body, "device_setup.js script missing")
        self.assertNotIn("editor-disasm-pre", body, "Disassembly should not be shown in Editor UI")
        self.assertNotIn("editor-hex-div", body, "Hex stream should not be shown in Editor UI")
        self.assertNotIn("editor-meta-pages", body, "Fixed pages field should not be in Editor UI")

    def test_02_wasm_mime_types(self):
        """Verify compiler.wasm is served with correct application/wasm MIME type"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/compiler.wasm")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        self.assertEqual(res.headers.get("Content-Type"), "application/wasm")
        data = res.read()
        self.assertTrue(len(data) > 1000)
        self.assertEqual(data[:4], b"\x00asm", "WASM magic header mismatch")

    def test_03_esptool_bundle_availability(self):
        """Verify esptool-bundle.js is accessible and contains ESPLoader export"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/esptool-bundle.js")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        content = res.read().decode("utf-8")
        self.assertIn("ESPLoader", content)
        self.assertIn("Transport", content)

    def test_04_app_market_index_and_allinone_scm(self):
        """Verify apps/index.json lists all apps with .allinone.scm mappings"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/apps/index.json")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        apps = json.loads(res.read().decode("utf-8"))
        self.assertGreaterEqual(len(apps), 13)

        for app in apps:
            self.assertIn("id", app)
            self.assertIn("name", app)
            self.assertIn("file", app)
            self.assertIn("scm", app)
            self.assertTrue(app["scm"].endswith(".allinone.scm"))

            # Check that the allinone.scm actually exists and serves
            conn.request("GET", f"/apps/{app['scm']}")
            res_scm = conn.getresponse()
            self.assertEqual(res_scm.status, 200, f"Missing {app['scm']}")
            scm_content = res_scm.read().decode("utf-8")
            self.assertIn("[app]", scm_content, f"Missing [app] header in {app['scm']}")
            self.assertIn(f"id = {app['id']}", scm_content)

    def test_05_in_browser_headless_test_suite(self):
        """Run the comprehensive HTML test suite in headless browser and verify 100% pass"""
        browser_exe = find_browser_executable()
        if not browser_exe:
            self.skipTest("No compatible headless browser (Edge/Chrome/Chromium) found")

        test_url = f"http://127.0.0.1:{self.port}/test_webrepl_features.html"
        cmd = [
            browser_exe,
            "--headless=new",
            "--disable-gpu",
            "--run-all-compositor-stages-before-draw",
            "--virtual-time-budget=10000",
            "--dump-dom",
            test_url
        ]

        match = None
        dom = ""
        for attempt in range(5):
            r = subprocess.run(cmd, capture_output=True, encoding="utf-8", errors="ignore")
            dom = r.stdout
            m = re.search(r'<div id="test-results"[^>]*data-status="([^"]+)"[^>]*data-total="(\d+)"[^>]*data-passed="(\d+)"[^>]*data-failed="(\d+)"', dom)
            if m and m.group(1) in ("PASSED", "FAILED"):
                match = m
                break
            time.sleep(1.0)

        self.assertIsNotNone(match, f"Could not find test-results in DOM. Output preview: {dom[:300]}")

        status, total, passed, failed = match.groups()
        print(f"\n[Browser Suite] Total: {total}, Passed: {passed}, Failed: {failed}, Status: {status}")
        if int(failed) > 0:
            failures = re.findall(r'<div class="test-item fail">.*?<span class="test-name">(.*?)</span>.*?<div class="test-err">(.*?)</div>', dom, re.DOTALL)
            for fname, ferr in failures:
                print(f"  [FAILED]: {fname}\n     ERROR: {ferr}")
        self.assertEqual(status, "PASSED", f"Browser test suite reported failures: {failed} failed")
        self.assertEqual(int(failed), 0)
        self.assertGreaterEqual(int(passed), 20)

    def test_06_server_with_proxy_co_location(self):
        """Verify server.py --with-proxy launches and serves both WebREPL and App Proxy"""
        proxy_port = find_free_port()
        webrepl_port = find_free_port()

        fixture = WebReplServerFixture(webrepl_port, with_proxy=True)
        # Patch the command line to use proxy_port
        fixture.proc = subprocess.Popen(
            [sys.executable, "server.py", "--no-tray", "--port", str(webrepl_port), "--with-proxy", "--proxy-port", str(proxy_port)],
            cwd=ROOT_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        try:
            # Poll for both ports
            up_webrepl = False
            up_proxy = False
            t0 = time.time()
            while time.time() - t0 < 5.0:
                try:
                    c1 = http.client.HTTPConnection("127.0.0.1", webrepl_port, timeout=1)
                    c1.request("GET", "/")
                    if c1.getresponse().status == 200:
                        up_webrepl = True
                except Exception:
                    pass

                try:
                    c2 = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=1)
                    c2.request("GET", "/health")
                    if c2.getresponse().status == 200:
                        up_proxy = True
                except Exception:
                    pass

                if up_webrepl and up_proxy:
                    break
                time.sleep(0.2)

            self.assertTrue(up_webrepl, "WebREPL port did not come up")
            self.assertTrue(up_proxy, "App Proxy port did not come up")
        finally:
            fixture.stop()

    def test_07_server_info_and_port_fallback(self):
        """Verify /api/server_info and automatic port fallback when preferred port is busy"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/api/server_info")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        info = json.loads(res.read().decode("utf-8"))
        self.assertTrue(info["success"])
        self.assertEqual(info["port"], self.port)
        self.assertTrue(len(info["ip"]) >= 7)

        # Verify automatic fallback when self.port is already bound
        proc2 = subprocess.Popen(
            [sys.executable, "server.py", "--no-tray", "--port", str(self.port)],
            cwd=ROOT_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        try:
            fallback_port = self.port + 1
            up_fallback = False
            t0 = time.time()
            while time.time() - t0 < 5.0:
                try:
                    c = http.client.HTTPConnection("127.0.0.1", fallback_port, timeout=1)
                    c.request("GET", "/api/server_info")
                    r = c.getresponse()
                    if r.status == 200:
                        data = json.loads(r.read().decode("utf-8"))
                        if data.get("port") == fallback_port:
                            up_fallback = True
                            break
                except Exception:
                    pass
                time.sleep(0.1)
            self.assertTrue(up_fallback, f"Expected server.py to fall back from busy port {self.port} to {fallback_port}")
        finally:
            proc2.terminate()
            try:
                proc2.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc2.kill()

    def test_08_dynamic_latest_release_discovery(self):
        """Verify /api/latest_release and ensure no hardcoded /releases/download/v1.0.0/ URLs exist"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/api/latest_release?repo=minischeme-webrepl")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        rel = json.loads(res.read().decode("utf-8"))
        self.assertTrue(rel.get("success"))
        self.assertEqual(rel.get("repo"), "minischeme-webrepl")
        self.assertIn("/releases/latest/download/", rel.get("download_base", ""))

        # Verify no hardcoded /releases/download/v1.0.0/ remains in client/installer files
        for fname in ("local_server.js", "editor_flasher.js", "app_manager.js", "index.html", "install.ps1", "server.py"):
            fpath = os.path.join(ROOT_DIR, fname)
            with open(fpath, "r", encoding="utf-8") as f:
                content = f.read()
            self.assertNotIn("/releases/download/v1.0.0/", content, f"Hardcoded release v1.0.0 found in {fname}")

    def test_09_weather_endpoint_with_token(self):
        """Verify /app/weather accepts per-hardware token and key parameter without persistence"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/app/weather?loc=Shanghai&token=hardware_token_abc_123&key=hardware_token_abc_123")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        data = json.loads(res.read().decode("utf-8"))
        self.assertIn("items", data)
        types = {it["t"] for it in data["items"]}
        self.assertIn("loc", types)
        self.assertIn("now", types)
        self.assertIn("day", types)
        self.assertIn("hours", types)
        self.assertIn("idx", types)

    def test_10_device_web_and_wifi_controller(self):
        """Verify AppWebPanel multi-tab device web page and WASM simulator WiFi controller"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        body = res.read().decode("utf-8")
        self.assertIn('id="sim-wifi-toggle"', body, "WASM WiFi toggle switch missing in index.html")
        self.assertIn('id="btn-app-web"', body, "Device Web button missing in index.html")

        # Verify app_web.js contains all 5 tabs and config handlers
        conn.request("GET", "/app_web.js")
        res_aw = conn.getresponse()
        self.assertEqual(res_aw.status, 200)
        content_aw = res_aw.read().decode("utf-8")
        self.assertIn("AppWebPanel", content_aw)
        self.assertIn('data-tab="app"', content_aw)
        self.assertIn('data-tab="system"', content_aw)
        self.assertIn('data-tab="config"', content_aw)
        self.assertIn('data-tab="manage"', content_aw)
        self.assertIn('data-tab="info"', content_aw)
        self.assertIn("aw-sys-wifi-online", content_aw)
        self.assertIn("saveSystemConfig", content_aw)
        self.assertIn("saveRawConfigIni", content_aw)
        self.assertIn("isSimWifiOnline", content_aw)
        self.assertIn("setSimWifiOnline", content_aw)

        # Verify device_setup.js contains ds-wifi-enable
        conn.request("GET", "/device_setup.js")
        res_ds = conn.getresponse()
        self.assertEqual(res_ds.status, 200)
        content_ds = res_ds.read().decode("utf-8")
        self.assertIn("ds-wifi-enable", content_ds)


if __name__ == "__main__":
    unittest.main(verbosity=2)


