#!/usr/bin/env bash
# MiniScheme WebREPL One-Click Installer for Linux / macOS
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.sh | bash

set -e

echo "=========================================================="
echo "   MiniScheme WebREPL - One-Click Installer (Linux/macOS) "
echo "=========================================================="

# 1. Check Python
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    echo "[!] Error: Python 3 is required but was not found." >&2
    echo "    Please install Python 3.10+ using your package manager." >&2
    exit 1
fi

PY_VER=$($PYTHON_CMD --version)
echo "[+] Found $PY_VER"

# 2. Target Directory
INSTALL_DIR="minischeme-webrepl"
if [ ! -d "$INSTALL_DIR" ]; then
    echo "[*] Cloning WebREPL repository..."
    if command -v git >/dev/null 2>&1; then
        git clone https://github.com/chk-jxcn/minischeme-webrepl.git "$INSTALL_DIR"
    else
        echo "[*] Git not found, downloading zip package..."
        ZIP_URL="https://github.com/chk-jxcn/minischeme-webrepl/archive/refs/heads/main.zip"
        curl -fsSL "$ZIP_URL" -o webrepl.zip
        unzip -q webrepl.zip
        mv minischeme-webrepl-main "$INSTALL_DIR"
        rm -f webrepl.zip
    fi
else
    echo "[*] Existing directory '$INSTALL_DIR' found. Updating..."
    if [ -d "$INSTALL_DIR/.git" ]; then
        (cd "$INSTALL_DIR" && git pull)
    fi
fi

cd "$INSTALL_DIR"

# 3. Optional dependencies
echo "[*] Checking Python dependencies..."
$PYTHON_CMD -m pip install --quiet pillow 2>/dev/null || true

# 4. Launch Local WebREPL Server
PORT=8080
echo ""
echo "=========================================================="
echo "   MiniScheme WebREPL is ready! Starting local server...  "
echo "   URL: http://localhost:$PORT                            "
echo "=========================================================="
echo ""

# Try opening default browser
if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "http://localhost:$PORT" &
elif command -v open >/dev/null 2>&1; then
    open "http://localhost:$PORT" &
fi

exec $PYTHON_CMD server.py --port $PORT
