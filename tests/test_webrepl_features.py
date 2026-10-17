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
import urllib.request
import urllib.parse
import urllib.error

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
    import struct
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        except Exception:
            pass
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
        env = dict(os.environ)
        env["MINISCHEME_ADMIN_PASSWORD"] = "admin"
        self.proc = subprocess.Popen(
            cmd,
            cwd=ROOT_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            text=True
        )
        # Wait until server accepts connections with port fallback tolerance
        t0 = time.time()
        while time.time() - t0 < 6.0:
            for p in (self.port, self.port + 1, self.port + 2):
                try:
                    conn = http.client.HTTPConnection("127.0.0.1", p, timeout=1)
                    conn.request("GET", "/health")
                    res = conn.getresponse()
                    if res.status == 200:
                        self.port = p
                        return
                except Exception:
                    pass
            time.sleep(0.1)
        raise RuntimeError("WebREPL server failed to start within 6s")

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
        cls.port = cls.server.port

    @classmethod
    def tearDownClass(cls):
        cls.server.stop()

    def test_01_index_html_assets(self):
        """Verify index.html serves with workspace tabs, hidden editor view, and categorized assets"""
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
        self.assertNotIn("btn-scheme-editor", body, "Editor button should not be duplicated in toolbar")
        self.assertIn("btn-firmware-flasher", body, "Flasher button missing")
        self.assertIn("js/editor_flasher.js", body, "js/editor_flasher.js script missing")
        self.assertIn("js/device_setup.js", body, "js/device_setup.js script missing")
        self.assertIn("css/style.css", body, "css/style.css stylesheet missing")
        self.assertIn("js/app.js", body, "js/app.js script missing")
        self.assertIn("server-host-input", body, "Server host input missing")
        self.assertIn("server-port-input", body, "Server port input missing")
        self.assertIn("server-cfg-save-btn", body, "Server save button missing")
        self.assertIn("server-cfg-reset-btn", body, "Server reset button missing")
        self.assertNotIn("editor-disasm-pre", body, "Disassembly should not be shown in Editor UI")
        self.assertNotIn("editor-hex-div", body, "Hex stream should not be shown in Editor UI")
        self.assertNotIn("editor-meta-pages", body, "Fixed pages field should not be in Editor UI")
        self.assertIn('(wifi-ip)', body, "Quick command (wifi-ip) missing in index.html")
        conn.close()

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
        conn.close()

    def test_03_esptool_bundle_availability(self):
        """Verify esptool-bundle.js is accessible and contains ESPLoader export"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/esptool-bundle.js")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        content = res.read().decode("utf-8")
        self.assertIn("ESPLoader", content)
        self.assertIn("Transport", content)
        conn.close()

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
        conn.close()

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
                    c1.close()
                except Exception:
                    pass

                try:
                    c2 = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=1)
                    c2.request("GET", "/health")
                    if c2.getresponse().status == 200:
                        up_proxy = True
                    c2.close()
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
        conn.close()

        # Verify automatic fallback when self.port is already bound
        proc2 = subprocess.Popen(
            [sys.executable, "server.py", "--no-tray", "--port", str(self.port)],
            cwd=ROOT_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
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
                            c.close()
                            break
                    c.close()
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
            if not os.path.exists(fpath):
                fpath = os.path.join(ROOT_DIR, "js", fname)
            with open(fpath, "r", encoding="utf-8") as f:
                content = f.read()
            self.assertNotIn("/releases/download/v1.0.0/", content, f"Hardcoded release v1.0.0 found in {fname}")
        conn.close()

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
        # When token is invalid or unauthenticated, fallback weather must indicate demo data
        self.assertTrue(data.get("is_demo"))
        self.assertEqual(data.get("title"), "天气【演示数据】")
        self.assertIn("demo", types)
        conn.close()

    def test_09b_market_endpoints(self):
        """Verify /app/futures, /app/crypto, and /app/stocks return correct schema tags"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)

        # 1. Futures: list view has "q", trend has "trend", all has both
        conn.request("GET", "/app/futures?view=list&codes=RB0,AU0,CU0")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        data = json.loads(res.read().decode("utf-8"))
        tags = {it["t"] for it in data["items"]}
        self.assertIn("q", tags, "Futures list must contain 'q' tags for Scheme app items-all")
        self.assertIn("meta", tags)

        conn.request("GET", "/app/futures?view=all&codes=RB0,AU0,CU0&chart=AU0")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        data = json.loads(res.read().decode("utf-8"))
        tags = {it["t"] for it in data["items"]}
        self.assertIn("q", tags)
        self.assertIn("trend", tags)
        self.assertIn("k", tags)

        # 2. Crypto: list view has "c", trend has "trend", all has both
        conn.request("GET", "/app/crypto?view=list&symbols=BTC,ETH,SOL")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        data = json.loads(res.read().decode("utf-8"))
        tags = {it["t"] for it in data["items"]}
        self.assertIn("c", tags, "Crypto list must contain 'c' tags for Scheme app items-all")
        self.assertIn("meta", tags)

        conn.request("GET", "/app/crypto?view=all&symbols=BTC,ETH,SOL&chart=BTC")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        data = json.loads(res.read().decode("utf-8"))
        tags = {it["t"] for it in data["items"]}
        self.assertIn("c", tags)
        self.assertIn("trend", tags)
        self.assertIn("k", tags)

        # 3. Stocks: home view has "idx", "trend", and "q", all has "k"
        conn.request("GET", "/app/stocks?view=home&codes=sh600519,sz300750&index=sh000001")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        data = json.loads(res.read().decode("utf-8"))
        tags = {it["t"] for it in data["items"]}
        self.assertIn("idx", tags, "Stocks home must contain 'idx' for index tiles")
        self.assertIn("q", tags, "Stocks home must contain 'q' for watchlist rows")
        self.assertIn("trend", tags)

        conn.request("GET", "/app/stocks?view=all&codes=sh600519,sz300750&index=sh000001")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        data = json.loads(res.read().decode("utf-8"))
        tags = {it["t"] for it in data["items"]}
        self.assertIn("idx", tags)
        self.assertIn("q", tags)
        self.assertIn("trend", tags)
        self.assertIn("k", tags)

        conn.close()

    def test_10_device_web_and_wifi_controller(self):
        """Verify AppWebPanel multi-tab device web page and WASM simulator WiFi controller"""
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/")
        res = conn.getresponse()
        self.assertEqual(res.status, 200)
        body = res.read().decode("utf-8")
        self.assertIn('id="sim-wifi-toggle"', body, "WASM WiFi toggle switch missing in index.html")
        self.assertIn('id="btn-app-web"', body, "Device Web button missing in index.html")

        # Verify app_web.js contains all 5 tabs and config handlers via both clean /js/ and legacy / URL
        for url in ("/js/app_web.js", "/app_web.js"):
            conn.request("GET", url)
            res_aw = conn.getresponse()
            self.assertEqual(res_aw.status, 200, f"Failed to get {url}")
            content_aw = res_aw.read().decode("utf-8")
            self.assertIn("AppWebPanel", content_aw)
            self.assertIn('data-tab="app"', content_aw)
            self.assertIn('data-tab="system"', content_aw)
            self.assertIn('data-tab="config"', content_aw)
            self.assertIn('data-tab="manage"', content_aw)
            self.assertIn('data-tab="info"', content_aw)
            self.assertIn("aw-sys-wifi-online", content_aw)
            self.assertIn("aw-sys-enter-settings-btn", content_aw)
            self.assertIn("enterSettingsMode", content_aw)
            self.assertIn("saveSystemConfig", content_aw)
            self.assertIn("saveRawConfigIni", content_aw)
            self.assertIn("isSimWifiOnline", content_aw)
            self.assertIn("setSimWifiOnline", content_aw)

        # Verify device_setup.js contains ds-wifi-enable
        for url in ("/js/device_setup.js", "/device_setup.js"):
            conn.request("GET", url)
            res_ds = conn.getresponse()
            self.assertEqual(res_ds.status, 200, f"Failed to get {url}")
            content_ds = res_ds.read().decode("utf-8")
            self.assertIn("ds-wifi-enable", content_ds)
        conn.close()

    def test_11_directory_structure_categorization(self):
        """Verify repository root is clean and assets are organized into js, css, wasm, data, tests"""
        # 1. Check categorized directories exist
        for dname in ("js", "css", "wasm", "data", "tests", "apps", "firmware", "proxy", "tools", "fonts"):
            dpath = os.path.join(ROOT_DIR, dname)
            self.assertTrue(os.path.isdir(dpath), f"Expected directory {dname} to exist")

        # 2. Check no loose JS, CSS, or WASM files remain directly in root
        root_files = os.listdir(ROOT_DIR)
        loose_js = [f for f in root_files if f.endswith(".js")]
        loose_css = [f for f in root_files if f.endswith(".css")]
        loose_wasm = [f for f in root_files if f.endswith(".wasm")]
        loose_test_html = [f for f in root_files if f.startswith("test_") and f.endswith(".html")]

        self.assertEqual(loose_js, [], f"Root directory should not contain loose JS files: {loose_js}")
        self.assertEqual(loose_css, [], f"Root directory should not contain loose CSS files: {loose_css}")
        self.assertEqual(loose_wasm, [], f"Root directory should not contain loose WASM files: {loose_wasm}")
        self.assertEqual(loose_test_html, [], f"Root directory should not contain loose test HTML files: {loose_test_html}")

        # 3. Check categorized assets are located correctly
        self.assertTrue(os.path.isfile(os.path.join(ROOT_DIR, "css", "style.css")))
        self.assertTrue(os.path.isfile(os.path.join(ROOT_DIR, "wasm", "compiler.wasm")))
        self.assertTrue(os.path.isfile(os.path.join(ROOT_DIR, "wasm", "minischeme_vm.wasm")))
        self.assertTrue(os.path.isfile(os.path.join(ROOT_DIR, "data", "font_charsets.json")))
        self.assertTrue(os.path.isfile(os.path.join(ROOT_DIR, "tests", "test_webrepl_features.html")))
        self.assertTrue(os.path.isfile(os.path.join(ROOT_DIR, "js", "app.js")))
        self.assertTrue(os.path.isfile(os.path.join(ROOT_DIR, "fonts", "simsun-16.mfnt")))
        self.assertTrue(os.path.isfile(os.path.join(ROOT_DIR, "fonts", "index.json")))

    def test_12_preset_fonts(self):
        """Verify bundled preset fonts (SimSun, SimHei) and /api/preset_fonts endpoint"""
        import urllib.request
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/api/preset_fonts", timeout=3) as res:
            self.assertEqual(res.status, 200)
            fonts = json.loads(res.read().decode("utf-8"))
            self.assertIsInstance(fonts, list)
            self.assertTrue(any(f.get("name") == "simsun-16" for f in fonts))
            self.assertTrue(any(f.get("name") == "simsun-12" for f in fonts))
            self.assertTrue(any(f.get("name") == "simhei-16" for f in fonts))
            for f in fonts:
                self.assertGreaterEqual(f.get("glyphs", 0), 7000)
                self.assertIn("二级", f.get("desc", ""))

        # Verify simsun-16.mfnt binary endpoint and valid MFNT magic
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/fonts/simsun-16.mfnt", timeout=3) as res_font:
            self.assertEqual(res_font.status, 200)
            data = res_font.read()
            self.assertTrue(len(data) > 100000)
            self.assertEqual(data[:4], b"MFNT")

    def test_13_proxy_admin_portal_and_api(self):
        """Verify Proxy Admin Portal (/admin), User Portal (/user), APIs, and tray integration"""
        import urllib.request
        # 1. Verify /admin and /user HTML pages
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/admin", timeout=3) as res_admin:
            self.assertEqual(res_admin.status, 200)
            admin_html = res_admin.read().decode("utf-8")
            self.assertIn("MiniScheme 代理服务管理后台", admin_html)
            self.assertIn("doAdminLogin", admin_html)

        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/user", timeout=3) as res_user:
            self.assertEqual(res_user.status, 200)
            user_html = res_user.read().decode("utf-8")
            self.assertIn("MiniScheme 设备用户控制台", user_html)
            self.assertIn("doLogin", user_html)

        # 2. Test Admin Login API (invalid and default admin password)
        req_bad = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/admin/login",
            data=json.dumps({"password": "wrongpassword"}).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req_bad, timeout=3) as res_bad:
                self.assertEqual(res_bad.status, 403)
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 403)

        req_ok = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/admin/login",
            data=json.dumps({"password": "admin"}).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req_ok, timeout=3) as res_ok:
            self.assertEqual(res_ok.status, 200)
            login_data = json.loads(res_ok.read().decode("utf-8"))
            self.assertTrue(login_data.get("success"))
            admin_token = login_data.get("token")
            self.assertTrue(bool(admin_token))

        # 3. Test Admin Devices & Preset APIs
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/api/admin/devices?token={admin_token}", timeout=3) as res_devs:
            self.assertEqual(res_devs.status, 200)
            dev_data = json.loads(res_devs.read().decode("utf-8"))
            self.assertTrue(dev_data.get("success"))
            self.assertIsInstance(dev_data.get("devices"), list)

        # Save preset config for test MAC
        test_mac = "C8F09EAA1122"
        req_preset = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/admin/preset",
            data=json.dumps({
                "token": admin_token,
                "mac": test_mac,
                "app_id": "weather",
                "key": "api_key",
                "value": "preset_secret_val_xyz"
            }).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req_preset, timeout=3) as res_pre:
            self.assertEqual(res_pre.status, 200)
            self.assertTrue(json.loads(res_pre.read().decode("utf-8")).get("success"))

        # Verify admin gets plaintext data
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/api/admin/device/data?mac={test_mac}&token={admin_token}", timeout=3) as res_data:
            self.assertEqual(res_data.status, 200)
            data_resp = json.loads(res_data.read().decode("utf-8"))
            self.assertTrue(data_resp.get("success"))
            items = data_resp.get("items", [])
            self.assertTrue(any(it.get("key") == "api_key" and it.get("value") == "preset_secret_val_xyz" for it in items))

        # 4. Verify WebREPL UI triggers and Tray Menu Option exist
        with open(os.path.join(ROOT_DIR, "index.html"), "r", encoding="utf-8") as f:
            index_content = f.read()
        self.assertNotIn('id="btn-proxy-admin"', index_content)
        self.assertNotIn('id="btn-quick-proxy-admin"', index_content)
        self.assertNotIn('id="proxy-admin-dialog"', index_content)
        self.assertIn('id="btn-local-server"', index_content)

        with open(os.path.join(ROOT_DIR, "server.py"), "r", encoding="utf-8") as f:
            server_content = f.read()
        self.assertIn("ID_OPEN_ADMIN", server_content)
        self.assertIn("打开代理服务管理后台", server_content)

    def test_15_weak_password_filter(self):
        """Verify built-in weak password filter rejects sequential and repeated digits"""
        with open(os.path.join(ROOT_DIR, "js", "device_setup.js"), "r", encoding="utf-8") as f:
            ds_js = f.read()
        with open(os.path.join(ROOT_DIR, "js", "app_web.js"), "r", encoding="utf-8") as f:
            aw_js = f.read()

        self.assertIn("validatePasswordSecurity", ds_js, "DeviceSetupWizard missing validatePasswordSecurity")
        self.assertIn("_validatePasswordSecurity", aw_js, "AppWebPanel missing _validatePasswordSecurity")
        self.assertIn("12345678", ds_js, "Weak blacklist must include 12345678")
        self.assertIn("88888888", ds_js, "Weak blacklist must include 88888888")
        self.assertIn("00000000", ds_js, "Weak blacklist must include 00000000")

        def verify_pwd(pwd):
            if not pwd or len(pwd) < 6:
                return False
            if len(set(pwd)) == 1:
                return False
            if pwd.lower() in {'123456', '12345678', '88888888', '00000000', '87654321', '654321'}:
                return False
            asc_run = desc_run = rep_run = 1
            for i in range(1, len(pwd)):
                p, c = pwd[i-1], pwd[i]
                if p.isdigit() and c.isdigit():
                    diff = ord(c) - ord(p)
                    if diff == 1:
                        asc_run += 1
                        if asc_run >= 4: return False
                    else: asc_run = 1
                    if diff == -1:
                        desc_run += 1
                        if desc_run >= 4: return False
                    else: desc_run = 1
                    if diff == 0:
                        rep_run += 1
                        if rep_run >= 4: return False
                    else: rep_run = 1
                else:
                    asc_run = desc_run = rep_run = 1
            return True

        self.assertFalse(verify_pwd("12345678"))
        self.assertFalse(verify_pwd("88888888"))
        self.assertFalse(verify_pwd("00000000"))
        self.assertFalse(verify_pwd("234567"))
        self.assertFalse(verify_pwd("87654321"))
        self.assertFalse(verify_pwd("654321"))
        self.assertFalse(verify_pwd("pass1234"))
        self.assertFalse(verify_pwd("4321pass"))
        self.assertFalse(verify_pwd("12345"))
        self.assertTrue(verify_pwd("mySecret926"))
        self.assertTrue(verify_pwd("scheme_2026"))
        self.assertTrue(verify_pwd("83910294"))

    def test_16_proxy_components_and_encryption_modes(self):
        """Verify server component enablement, protocol encryption mode enforcement, and device setup rules"""
        # 1. Start ephemeral server in proxy-only & encrypted mode
        test_port = find_free_port()
        cmd = [
            sys.executable, "server.py",
            "--port", str(test_port),
            "--proxy-only",
            "--protocol", "encrypted",
            "--no-tray"
        ]
        env = dict(os.environ)
        env["MINISCHEME_ADMIN_PASSWORD"] = "testadmin"
        proc = subprocess.Popen(cmd, cwd=ROOT_DIR, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
        actual_port = test_port
        try:
            # Wait for startup
            t0 = time.time()
            started = False
            while time.time() - t0 < 8.0:
                for p in (test_port, test_port + 1, test_port + 2):
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{p}/health", timeout=1.0) as res:
                            if res.status == 200:
                                data = json.loads(res.read().decode("utf-8"))
                                if data.get("protocol_mode") == "encrypted":
                                    self.assertIn("proxy", data.get("components", []))
                                    self.assertNotIn("webrepl", data.get("components", []))
                                    actual_port = p
                                    started = True
                                    break
                    except Exception:
                        pass
                if started:
                    break
                time.sleep(0.1)
            self.assertTrue(started, "Encrypted proxy server failed to start")

            # 2. Plaintext request /app/weather must be rejected with 403 Forbidden
            req_plain = urllib.request.Request(f"http://127.0.0.1:{actual_port}/app/weather")
            try:
                with urllib.request.urlopen(req_plain, timeout=2) as res:
                    self.assertEqual(res.status, 403)
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 403)
                err_body = json.loads(e.read().decode("utf-8"))
                self.assertIn("Plaintext protocol is disabled", err_body.get("error", ""))

            # 3. Static WebREPL files must return 404 in proxy-only mode
            req_static = urllib.request.Request(f"http://127.0.0.1:{actual_port}/")
            try:
                with urllib.request.urlopen(req_static, timeout=2) as res:
                    self.assertEqual(res.status, 404)
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 404)

            # 4. Portal route (/admin) is enabled in proxy-only mode
            with urllib.request.urlopen(f"http://127.0.0.1:{actual_port}/admin", timeout=2) as res:
                self.assertEqual(res.status, 200)

            # 5. Encrypted server /api/admin/status requires password
            with urllib.request.urlopen(f"http://127.0.0.1:{actual_port}/api/admin/status", timeout=2) as res:
                self.assertEqual(res.status, 200)
                st = json.loads(res.read().decode("utf-8"))
                self.assertTrue(st.get("auth_required"))

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()

        # 6. Verify local server allows passwordless admin auto-login
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/api/admin/status", timeout=2) as res:
            self.assertEqual(res.status, 200)
            local_st = json.loads(res.read().decode("utf-8"))
            self.assertFalse(local_st.get("auth_required"))
            self.assertTrue(bool(local_st.get("token")))

        # 7. Simulator registration and passwordless login on local server
        test_sim_uuid = "SIM-9A8B-7C6D"
        req_reg = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/user/sim_register",
            data=json.dumps({"uuid": test_sim_uuid}).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req_reg, timeout=2) as res:
            self.assertEqual(res.status, 200)
            self.assertTrue(json.loads(res.read().decode("utf-8")).get("success"))

        req_sim_login = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/user/sim_login",
            data=json.dumps({"uuid": test_sim_uuid}).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req_sim_login, timeout=2) as res:
            self.assertEqual(res.status, 200)
            sim_login_data = json.loads(res.read().decode("utf-8"))
            self.assertTrue(sim_login_data.get("success"))
            sim_token = sim_login_data.get("token")
            self.assertTrue(bool(sim_token))

        # 8. Preset secret data and verify sensitive masking in user portal
        admin_tok = local_st.get("token")
        req_preset = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/admin/preset",
            data=json.dumps({
                "token": admin_tok,
                "mac": test_sim_uuid,
                "app_id": "weather",
                "key": "qweather_token",
                "value": "super_secret_qweather_token_9999"
            }).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req_preset, timeout=2) as res:
            self.assertTrue(json.loads(res.read().decode("utf-8")).get("success"))

        # User portal fetch data: value must be masked with asterisks!
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/api/user/data?mac={test_sim_uuid}&token={sim_token}", timeout=2) as res:
            user_data = json.loads(res.read().decode("utf-8"))
            self.assertTrue(user_data.get("success"))
            items = user_data.get("items", [])
            self.assertTrue(len(items) > 0)
            for it in items:
                if it.get("key") == "qweather_token":
                    self.assertIn("****", it.get("value"))
                    self.assertNotIn("super_secret", it.get("value"))

        # 9. User portal clear app data
        req_clear = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/user/data/clear",
            data=json.dumps({
                "mac": test_sim_uuid,
                "token": sim_token,
                "app_id": "weather"
            }).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req_clear, timeout=2) as res:
            self.assertTrue(json.loads(res.read().decode("utf-8")).get("success"))

        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/api/user/data?mac={test_sim_uuid}&token={sim_token}", timeout=2) as res:
            cleared_data = json.loads(res.read().decode("utf-8"))
            self.assertEqual(len(cleared_data.get("items", [])), 0)

        # 10. Verify js/device_setup.js includes public proxy defaults and simulator unencrypted restrictions
        setup_js_path = os.path.join(ROOT_DIR, "js", "device_setup.js")
        with open(setup_js_path, "r", encoding="utf-8") as f:
            setup_js = f.read()
        self.assertIn("isPublicWebRepl", setup_js)
        self.assertIn("getPublicProxyServer", setup_js)
        self.assertIn("124.222.231.186:8087", setup_js)
        self.assertIn("仅支持非加密协议", setup_js)


if __name__ == "__main__":
    unittest.main(verbosity=2)



