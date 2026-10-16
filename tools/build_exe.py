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
        ("style.css", "."),
        ("font_charsets.json", "."),
        ("compiler.wasm", "."),
        ("minischeme_vm.wasm", "."),
        ("apps", "apps"),
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
        "--hidden-import", "make_font",
        "server.py",
    ])

    print("[*] Running PyInstaller:", " ".join(cmd))
    subprocess.run(cmd, check=True)
    exe_path = os.path.join(ROOT, "dist", "MiniScheme-WebREPL.exe" if os.name == "nt" else "MiniScheme-WebREPL")
    if os.path.exists(exe_path):
        print(f"[+] Successfully built standalone executable: {exe_path} ({os.path.getsize(exe_path)} bytes)")
    else:
        sys.exit(f"[!] Expected output not found: {exe_path}")


if __name__ == "__main__":
    main()
