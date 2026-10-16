# MiniScheme WebREPL

A modern, browser-based integrated development environment (IDE), bytecode compiler, device telemetry console, and Web Serial firmware flasher for MiniScheme.

🌐 **Online Demo**: [https://chk-jxcn.github.io/minischeme-webrepl/](https://chk-jxcn.github.io/minischeme-webrepl/)

## Quick Start (One-Click Installer)

Install and launch WebREPL locally in seconds using a single command:

### Windows (PowerShell)
```powershell
irm https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.ps1 | iex
```

### Linux & macOS (Bash)
```bash
curl -fsSL https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.sh | bash
```

The script automatically downloads/clones the repository, installs Python dependencies, starts the local WebREPL server, and opens `http://localhost:8080` in your default browser.

---

## Initial Device Setup Wizard (Web Serial)

When connecting a new or unconfigured ESP32 hardware device via USB / Web Serial:
1. Click **"连接串口 (Connect Serial)"** in the top navigation bar.
2. Click **"⚙️ 初始设备配置 (Device Setup)"** in the toolbar.
3. Fill in:
   - **WiFi Information**: SSID and password.
   - **External Server**: Proxy address (`http://<host>:8087`) and hardware password.
   - **Default Boot App**: Bundled **万年历 (Calendar)** is selected by default.
4. Click **"保存配置并重启设备 (Save & Reboot)"**. The WebREPL writes `/spiffs/config.ini`, uploads the default app if missing, and restarts the device immediately.

---

## Key Features
- **Web Serial Firmware Flasher**: Flash firmware directly from the browser to ESP32 devices via Web Serial API. Supports downloading official releases from GitHub or uploading local `.bin` images.
- **In-Browser Scheme IDE & Compiler**:
  - Code editor with auto-indentation and syntax support.
  - Automatic metadata and API version extraction from `.scm` files.
  - In-browser compilation via `compiler.wasm` to binary `.msbc` bytecode.
  - Download `.msbc`, save to browser `localStorage`, or upload directly to connected hardware.
- **Password-Protected Device Access**:
  - Connect to hardware via WiFi HTTP with optional authentication header (`X-MiniScheme-Auth`) using lightweight string comparison.
- **Font Generation Suite**:
  - Generate compact bitmap fonts (`.mfnt`) from TTF/WOFF files directly in browser or through backend tools.
- **App Market Integration**:
  - Browse and download community apps from GitHub, modify code in the online editor, and deploy with one click.
- **Co-located Proxy Support**:
  - Launch with `--with-proxy` to automatically run the local application proxy and protocol converter alongside the WebREPL server.

## Running Locally

```bash
python server.py --port 8080
```

To run with the local application proxy & protocol converter enabled:
```bash
python server.py --port 8080 --with-proxy
```

Then navigate to `http://localhost:8080` in Chrome, Edge, or any modern Chromium-based browser.

## Project Structure

```
minischeme-webrepl/
├── apps/               # Built-in Scheme application packages (.scm, .msbc, meta.ini)
├── css/                # Web stylesheets (style.css)
├── data/               # Static data assets (font_charsets.json)
├── firmware/           # Prebuilt ESP32 firmware binaries & manifest
├── js/                 # Client JavaScript frontend modules
├── proxy/              # App Proxy & Protocol Converter service
├── tests/              # Test suite (Python integration & browser HTML suites)
├── tools/              # Developer & packaging tools (build_exe.py, make_font.py)
├── wasm/               # WebAssembly binaries (minischeme_vm.wasm, compiler.wasm) & C sources
├── index.html          # WebREPL web interface entry point
├── server.py           # Local server & Windows system tray application
└── install.ps1 / .sh   # One-line installer scripts
```

## License
MIT License
