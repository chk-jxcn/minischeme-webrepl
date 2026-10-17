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

    # 2. Sync compiled .msbc binaries, standalone .allinone.scm files, and rich index.json
    dist_src = os.path.join(ROOT_DIR, "minischeme-apps", "dist")
    if os.path.exists(dist_src):
        for msbc_file in glob.glob(os.path.join(dist_src, "*.msbc")):
            shutil.copy2(msbc_file, apps_dst)
        for scm_file in glob.glob(os.path.join(dist_src, "*.allinone.scm")):
            shutil.copy2(scm_file, apps_dst)
        print(f"[+] Synced compiled MSBC binaries and allinone SCM files to {apps_dst}")

    index_src = os.path.join(ROOT_DIR, "minischeme-apps", "apps", "index.json")
    if not os.path.exists(index_src):
        index_src = os.path.join(dist_src, "index.json")
    if os.path.exists(index_src):
        shutil.copy2(index_src, os.path.join(apps_dst, "index.json"))
        print(f"[+] Synced rich app market index.json to {apps_dst}")

    # 3. Sync firmware binaries from minischeme-esp32 if built
    fw_src = os.path.join(ROOT_DIR, "minischeme-esp32", "build")
    fw_dst = os.path.join(BASE_DIR, "firmware")
    if os.path.exists(fw_src):
        os.makedirs(fw_dst, exist_ok=True)
        bin_map = {
            os.path.join(fw_src, "minischeme_esp32.bin"): os.path.join(fw_dst, "minischeme_esp32.bin"),
            os.path.join(fw_src, "bootloader", "bootloader.bin"): os.path.join(fw_dst, "bootloader.bin"),
            os.path.join(fw_src, "partition_table", "partition-table.bin"): os.path.join(fw_dst, "partition-table.bin"),
        }
        for src_path, dst_path in bin_map.items():
            if os.path.exists(src_path):
                shutil.copy2(src_path, dst_path)
                print(f"[+] Synced built firmware binary: {os.path.basename(dst_path)} ({os.path.getsize(dst_path)} B)")

    # 4. Check WASM artifacts
    vm_wasm = os.path.join(BASE_DIR, "wasm", "minischeme_vm.wasm")
    comp_wasm = os.path.join(BASE_DIR, "wasm", "compiler.wasm")
    if not (os.path.exists(vm_wasm) and os.path.exists(comp_wasm)):
        vm_wasm = os.path.join(BASE_DIR, "minischeme_vm.wasm")
        comp_wasm = os.path.join(BASE_DIR, "compiler.wasm")
    if os.path.exists(vm_wasm) and os.path.exists(comp_wasm):
        print(f"[+] WASM binaries verified: minischeme_vm.wasm ({os.path.getsize(vm_wasm)} B), compiler.wasm ({os.path.getsize(comp_wasm)} B)")
    else:
        print("[!] Warning: WASM binaries missing in web_repl directory.")

    print("[+] Public WebREPL deployment bundle successfully updated!")


if __name__ == "__main__":
    sync_core()
