"""The tests' apps: the WebREPL carries none (the page downloads them), so the market's
apps are put into the git-ignored apps/ first (tools/fetch_apps.py: from a minischeme-apps
checkout beside this one, else GitHub); the servers the tests start sync nothing."""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from fetch_apps import ensure_apps  # noqa: E402

os.environ.setdefault("MINISCHEME_MARKET_SYNC", "0")
ensure_apps()
