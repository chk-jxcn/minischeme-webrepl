#!/usr/bin/env python3
"""
Packages server.py and all WebREPL + App Proxy assets into a standalone
single-file Windows executable (dist/MiniScheme-WebREPL.exe) using PyInstaller.
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    os.chdir(ROOT)
    sep = ";" if os.name == "nt" else ":"

    data_items = [
        ("index.html", "."),
        ("css", "css"),
        ("js", "js"),
        ("wasm", "wasm"),
        ("data", "data"),
        ("apps", "apps"),
        ("fonts", "fonts"),
        ("firmware", "firmware"),
        ("proxy", "proxy"),
        ("tools", "tools"),
    ]

    for f in os.listdir(ROOT):
        if f.endswith(".js") or f.endswith(".html"):
            if (f, ".") not in data_items:
                data_items.append((f, "."))

    cmd = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--clean",
        "--onefile",
        "--noconsole",
        "--name",
        "MiniScheme-WebREPL",
    ]

    for src, dst in data_items:
        if os.path.exists(os.path.join(ROOT, src)):
            cmd.extend(["--add-data", f"{src}{sep}{dst}"])

    cmd.extend([
        "--hidden-import", "proxy",
        "--hidden-import", "proxy.server",
        "--hidden-import", "proxy.endpoints",
        "--hidden-import", "proxy.database",
        "--hidden-import", "proxy.crypto",
        "--hidden-import", "proxy.cache",
        "--hidden-import", "proxy.user_portal",
        "--hidden-import", "proxy.admin_portal",
        "--hidden-import", "proxy.channel",
        "--hidden-import", "proxy.security",
        "--hidden-import", "proxy.hwkey_js",
        "--hidden-import", "proxy.admin_password",
        "--hidden-import", "proxy.calendar_data",
        # the calendar's lunar_python, vendored in proxy/vendor (MIT)
        "--paths", os.path.join("proxy", "vendor"),
        "--collect-submodules", "lunar_python",
        "--hidden-import", "make_font",
    ])
    try:   # zoneinfo has no time zone database on Windows: the world clocks need tzdata
        import tzdata  # noqa: F401
        cmd.extend(["--collect-all", "tzdata"])
    except ImportError:
        print("[!] tzdata is not installed: the exe's world clocks will be empty (pip install tzdata)")
    cmd.append("server.py")

    print("[*] Running PyInstaller:", " ".join(cmd))
    subprocess.run(cmd, check=True)
    exe_path = os.path.join(ROOT, "dist", "MiniScheme-WebREPL.exe" if os.name == "nt" else "MiniScheme-WebREPL")
    if os.path.exists(exe_path):
        print(f"[+] Successfully built standalone executable: {exe_path} ({os.path.getsize(exe_path)} bytes)")
    else:
        sys.exit(f"[!] Expected output not found: {exe_path}")


if __name__ == "__main__":
    main()
