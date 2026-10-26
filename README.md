# MiniScheme WebREPL

A browser IDE, bytecode compiler, WASM device simulator, device console and Web Serial firmware flasher for MiniScheme.

🌐 **Online demo**: [https://chk-jxcn.github.io/minischeme-webrepl/](https://chk-jxcn.github.io/minischeme-webrepl/)

## Quick start (one-line installer)

### Windows (PowerShell)
```powershell
irm https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.ps1 | iex
```

### Linux & macOS (Bash)
```bash
curl -fsSL https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.sh | bash
```

The script downloads the latest release (on Windows the single-file tray program `MiniScheme-WebREPL.exe`), starts the local server on port 8087 (the next free port if that one is busy) and opens it in the browser. The local server also runs the app proxy and protocol converter.

---

## First setup of a device (serial)

1. Click **连接设备** with the serial mode and choose the board's USB port. A board without WiFi settings opens the setup dialog by itself; otherwise use the setup button next to **连接设备**.
2. The dialog first reads the board's `/spiffs/config.ini`. If that read fails (a serial timeout), saving is refused until **⟳ 读取设备配置** succeeds, so the board's other settings are never replaced by defaults.
3. Fill in:
   - **WiFi**: SSID and password (the router's own password; no strength rule).
   - **App proxy / protocol converter**: `http://<host>:8087` (the service IP comes from the backend settings).
   - **Hardware password**: at least 6 characters, no simple sequences (12345678, 88888888, ...). Once set it is shown and locked. It becomes the device's web page / API password (`[http] http_password`) and registers the board with the converter (`[channel] channel_key`).
4. Click **保存配置并重启设备**. The WebREPL writes `/spiffs/config.ini` (keeping `config_version = 3` and every other key), remembers the password for its next requests and restarts the board, which boots into the built-in settings until an app is installed.

The simulated device needs no password and uses the local proxy.

---

## Features
- **Firmware flasher (Web Serial)**: the latest release's images, or local `.bin` files. With **写入系统字库** (on by default) it also writes the release's font ROM (simsun-16, all of GB2312) at the address its manifest gives (`0x1a0000` since firmware 1.0.74, `0x190000` before); this replaces the font ROM, so fonts installed before must be installed again. When the release's partition table differs from the board's (1.0.74 moved the file system), the flasher says so and asks first: the board's files are erased by such a flash, so back them up in the file manager (**⬇ 备份全部**, one zip) and write them back afterwards (**⬆ 恢复备份**); the font ROM is then always written. A release is taken with its `firmware-manifest.json` from one source (the local server, the GitHub Release, this site's `firmware/`) and every file is checked against the manifest's SHA-256; after writing, esptool-js reads each region back and compares its MD5. A failed flash releases the serial port for the next try.
- **Scheme editor and compiler**: compile to `.msbc` in the browser (`compiler.wasm`), simulate, download, or install on the board. An app opens as its own code (its meta.ini as the `;;;` header); the 应用库 dropdown picks the app library (applib) version compiled before it (versions `MAJOR.MINOR`: the newest that serves the app's `applib`), and the image gets the whole meta.ini and the app's web page, as `build_apps.py` makes it. **📖 API 文档** lists the firmware API and the chosen library's definitions (search, details, insert at the cursor).
- **Device access over WiFi**: the device password is sent in the `X-MiniScheme-Auth` header (never in page URLs); the settings tab's password is written as the firmware's `[http] http_password` and applied at once. A failed read of `config.ini` stops a save instead of writing defaults.
- **App pages**: an app's own web page runs in a sandboxed frame (no access to the WebREPL's storage or device connection; it talks to the app through `postMessage`).
- **Device page** (🌐 设备网页): the board's own page for the simulator, with the same tabs: the app's page, system and app configuration, app management, color schemes (day / night switching, the `theme.css` editor with a preview) and system information. For a combined app (合集) a dropdown over the app's page picks its own page (which pages show, in which order, the carousel, the members' alerts) or one of its members' pages; only the page picked is loaded.
- **WASM simulator**: the same C runtime as the firmware (stack traces on in the simulator). It starts with the firmware's font ROM (`firmware/fontrom.bin`: **simsun-16, all of GB2312 levels 1 and 2**), so Chinese text needs no font generation; 16 px text uses it by default, as on the board. Characters the font ROM lacks (emoji, Korean, traditional) come from the font server like on a board (config.ini `[fonts] font_server`, set in the settings tab; minischeme-proxy `font_server.py`).
- **Headless simulator** (`tools/sim.py`, for tests and agents): `--app`, `--install` (an image installed as the market does, its web page included), `--press`, `--wait`, `--shot`, `--webshot` (the app's web page), `--eval`, `--config`, `--js`, `--repl`; `--help` lists them.
- **App market**: the apps of [minischeme-apps](https://github.com/chk-jxcn/minischeme-apps); install, edit and deploy. This repository carries no app: the page takes the newest minischeme-apps release (⟳ 刷新 looks it up again) through jsDelivr or raw GitHub and keeps the files in the browser (offline: the last ones), `js/app_source.js`. Served by a local `server.py`, the list also shows the apps of the git-ignored `apps/` that differ from the market (`build_apps.py --sync` in minischeme-apps), marked 本地编译. **⬆ 上传应用** installs an app image of your own (an `.msbc` with its `[app]` metadata, from `build_apps.py` or the editor) into `/spiffs/user/<id>/`, where the market's updates never replace it (an app of that id already installed is replaced where it is).
- **Fonts**: bitmap font (`.mfnt`) generation and the font ROM.

## Running from source

```bash
pip install Pillow fontTools      # optional: only the font generator needs them
python server.py                  # http://127.0.0.1:8087, app proxy included
python tools/fetch_apps.py        # the market's apps in apps/ (for tools/sim.py; the tests do it themselves)
python -m pytest tests            # integration tests (starts its own server)
```

The local server's `/market/` (a board's market on this network) serves the PC's builds in `apps/`, then `market_cache/`, which it keeps up to date from the newest minischeme-apps release (minischeme-proxy `proxy/market_sync.py`; `[market] github_sync = 0` in config.ini turns it off).

The local server's admin portal (`/admin`) uses `config.ini [security] admin_password` (read again at every login); without one the password is `admin`, and the portal says so and offers to change it (the new one is written into config.ini). The tray menu opens config.ini ("打开配置文件"). The proxy-only deployment (the public server) has no default. Its CORS answers go only to the published WebREPL and pages on this network, and it never serves its own files (`config.ini`, the database, sources).

## Project structure

```
minischeme-webrepl/
├── apps/       # git-ignored: the market's apps for tools/sim.py, the tests and local builds (tools/fetch_apps.py, build_apps.py --sync)
├── css/ data/ fonts/
├── firmware/   # the latest firmware release (images + firmware-manifest.json with SHA-256)
├── js/         # front end
├── proxy/      # app proxy and protocol converter (same files as minischeme-proxy)
├── tests/      # Python integration tests and browser suites
├── tools/      # sim.py, build_exe.py, make_font.py, deploy_public_proxy.py
├── wasm/       # minischeme_vm.wasm, compiler.wasm and their C bridge
├── index.html
├── server.py   # local server and Windows tray program
└── install.ps1 / install.sh
```

See [AGENT_DEVELOPMENT_GUIDE.md](AGENT_DEVELOPMENT_GUIDE.md) for the protocols and the five repositories.

## License
MIT License
