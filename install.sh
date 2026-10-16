#!/usr/bin/env bash
# MiniScheme WebREPL One-Click Installer for Linux / macOS
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.sh | bash

set -e

echo "=========================================================="
echo "   MiniScheme WebREPL - One-Click Installer (Linux/macOS) "
echo "=========================================================="

if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    echo "[!] Error: Python 3 is required but was not found." >&2
    exit 1
fi

INSTALL_DIR="minischeme-webrepl"
if [ ! -d "$INSTALL_DIR" ]; then
    echo "[*] Cloning WebREPL repository..."
    if command -v git >/dev/null 2>&1; then
        git clone https://github.com/chk-jxcn/minischeme-webrepl.git "$INSTALL_DIR"
    else
        ZIP_URL="https://github.com/chk-jxcn/minischeme-webrepl/archive/refs/heads/main.zip"
        curl -fsSL "$ZIP_URL" -o webrepl.zip
        unzip -q webrepl.zip
        mv minischeme-webrepl-main "$INSTALL_DIR"
        rm -f webrepl.zip
    fi
else
    if [ -d "$INSTALL_DIR/.git" ]; then
        (cd "$INSTALL_DIR" && git pull)
    fi
fi

cd "$INSTALL_DIR"
$PYTHON_CMD -m pip install --quiet pillow 2>/dev/null || true

PORT=8087
echo "=========================================================="
echo "   MiniScheme WebREPL starting (default port $PORT)...    "
echo "=========================================================="

exec $PYTHON_CMD server.py --port $PORT --open-browser
