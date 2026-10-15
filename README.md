# MiniScheme WebREPL

A modern, browser-based integrated development environment (IDE), bytecode compiler, device telemetry console, and Web Serial firmware flasher for MiniScheme.

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

## Deployment & Sync
When the core MiniScheme interpreter or ESP-IDF firmware is updated, re-sync the public deployment bundle:
```bash
python tools/sync_from_core.py
```

## License
MIT License
