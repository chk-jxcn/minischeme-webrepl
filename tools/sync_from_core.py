#!/usr/bin/env python3
"""Sync script to update public WebREPL deployment files from minischeme and minischeme-esp32 projects."""

import glob
import json
import os
import shutil
import sys

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT_DIR = os.path.dirname(BASE_DIR)


def sync_core():
    print("[*] Synchronizing WebREPL deployment bundle from core projects...")

    # 1. Sync from minischeme-apps
    apps_src = os.path.join(ROOT_DIR, "minischeme-apps", "apps")
    apps_dst = os.path.join(BASE_DIR, "apps")
    if os.path.exists(apps_src):
        os.makedirs(apps_dst, exist_ok=True)
        for app_folder in glob.glob(os.path.join(apps_src, "*")):
            if os.path.isdir(app_folder):
                app_name = os.path.basename(app_folder)
                target = os.path.join(apps_dst, app_name)
                shutil.copytree(app_folder, target, dirs_exist_ok=True)
        print(f"[+] Synced application sources to {apps_dst}")

    # 2. Build index.json
    index_path = os.path.join(apps_dst, "index.json")
    app_list = []
    for d in glob.glob(os.path.join(apps_dst, "*")):
        if os.path.isdir(d):
            app_id = os.path.basename(d)
            if app_id != "lib":
                app_list.append(app_id)
    app_list.sort()
    with open(index_path, "w", encoding="utf-8") as f:
        json.dump({"apps": app_list}, f, indent=2)
    print(f"[+] Re-generated {index_path} with {len(app_list)} apps.")

    # 3. Check WASM artifacts
    vm_wasm = os.path.join(BASE_DIR, "minischeme_vm.wasm")
    comp_wasm = os.path.join(BASE_DIR, "compiler.wasm")
    if os.path.exists(vm_wasm) and os.path.exists(comp_wasm):
        print(f"[+] WASM binaries verified: minischeme_vm.wasm ({os.path.getsize(vm_wasm)} B), compiler.wasm ({os.path.getsize(comp_wasm)} B)")
    else:
        print("[!] Warning: WASM binaries missing in web_repl directory.")

    print("[+] Public WebREPL deployment bundle successfully updated!")


if __name__ == "__main__":
    sync_core()
