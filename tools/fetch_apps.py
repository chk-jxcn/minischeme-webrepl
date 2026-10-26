#!/usr/bin/env python3
"""The market's apps in this checkout's apps/ (git-ignored), for tools/sim.py, the tests
and a local server.py: the WebREPL carries no app of its own (the page downloads them
from minischeme-apps on GitHub, js/app_source.js).

    python tools/fetch_apps.py            # only when apps/index.json is missing
    python tools/fetch_apps.py --force    # again

From a minischeme-apps checkout beside this one (its dist/ and apps/<id>/ sources, as
its build_apps.py --sync copies them), else the newest release tag of
chk-jxcn/minischeme-apps through jsDelivr (the images and sources the index names,
dist/lib/ and dist/api.json).
"""
import json
import os
import re
import shutil
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPS = os.path.join(ROOT, "apps")
SIBLING = os.path.join(ROOT, "..", "minischeme-apps")
REPO = "chk-jxcn/minischeme-apps"


def _get(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "MiniScheme-WebREPL"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def _copy_tree(src, dst):
    for base, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        rel = os.path.relpath(base, src)
        os.makedirs(os.path.join(dst, rel), exist_ok=True)
        for f in files:
            shutil.copy2(os.path.join(base, f), os.path.join(dst, rel, f))


def from_sibling():
    dist = os.path.join(SIBLING, "dist")
    if not os.path.isfile(os.path.join(dist, "index.json")):
        return False
    os.makedirs(APPS, exist_ok=True)
    for f in os.listdir(dist):
        p = os.path.join(dist, f)
        if os.path.isfile(p) and (f.endswith((".msbc", ".allinone.scm")) or f in ("index.json", "api.json")):
            shutil.copy2(p, os.path.join(APPS, f))
    if os.path.isdir(os.path.join(dist, "lib")):
        _copy_tree(os.path.join(dist, "lib"), os.path.join(APPS, "lib"))
    src = os.path.join(SIBLING, "apps")
    for d in os.listdir(src):
        if os.path.isdir(os.path.join(src, d)) and d != "lib":
            for f in os.listdir(os.path.join(src, d)):
                if not f.endswith((".msbc", ".allinone.scm")) and os.path.isfile(os.path.join(src, d, f)):
                    os.makedirs(os.path.join(APPS, d), exist_ok=True)
                    shutil.copy2(os.path.join(src, d, f), os.path.join(APPS, d, f))
    print(f"[fetch_apps] copied from {os.path.normpath(SIBLING)}")
    return True


def newest_tag():
    try:
        return json.loads(_get(f"https://api.github.com/repos/{REPO}/releases/latest", 20))["tag_name"]
    except Exception:
        vs = [v["version"] for v in json.loads(_get(f"https://data.jsdelivr.com/v1/packages/gh/{REPO}", 20))["versions"]
              if re.fullmatch(r"\d+(\.\d+)*", v.get("version", ""))]
        return "v" + max(vs, key=lambda v: tuple(int(x) for x in v.split(".")))


def from_github():
    tag = newest_tag()
    base = f"https://cdn.jsdelivr.net/gh/{REPO}@{tag}/"

    def save(repo_path, local_rel):
        data = _get(base + repo_path)
        path = os.path.join(APPS, *local_rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        return data

    index = json.loads(save("dist/index.json", "index.json"))
    for a in index:
        for f in (a.get("file"), a.get("scm")):
            if f:
                save(f"dist/{f}", f)
        for key in ("source", "meta", "web_page"):
            if a.get(key):
                save(a[key], a[key][len("apps/"):])
    save("dist/api.json", "api.json")
    libs = json.loads(save("dist/lib/index.json", "lib/index.json"))
    for v in libs.get("versions", []):
        for f in v.get("files", []) + ["api.json"]:
            save(f"dist/lib/{v['version']}/{f}", f"lib/{v['version']}/{f}")
    print(f"[fetch_apps] downloaded {tag} ({len(index)} apps) from jsDelivr")
    return True


def ensure_apps(force=False):
    """apps/ with the market's apps; True when they are there."""
    if not force and os.path.isfile(os.path.join(APPS, "index.json")):
        return True
    return from_sibling() or from_github()


if __name__ == "__main__":
    sys.exit(0 if ensure_apps("--force" in sys.argv[1:]) else 1)
