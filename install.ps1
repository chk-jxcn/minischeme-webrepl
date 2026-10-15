# MiniScheme WebREPL One-Click Installer for Windows (PowerShell)
# Usage:
#   irm https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   MiniScheme WebREPL - One-Click Installer (Windows)     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Check Python
$pythonCmd = $null
if (Get-Command python -ErrorAction SilentlyContinue) {
    $pythonCmd = "python"
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $pythonCmd = "py"
}

if (-not $pythonCmd) {
    Write-Host "[!] Error: Python 3 is required but was not found in PATH." -ForegroundColor Red
    Write-Host "    Please install Python 3.10+ from https://www.python.org/ or Windows Store." -ForegroundColor Yellow
    exit 1
}

$pyVer = & $pythonCmd --version
Write-Host "[+] Found $pyVer" -ForegroundColor Green

# 2. Target Directory
$installDir = "minischeme-webrepl"
if (-not (Test-Path $installDir)) {
    Write-Host "[*] Cloning WebREPL repository..." -ForegroundColor Yellow
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git clone https://github.com/chk-jxcn/minischeme-webrepl.git $installDir
    } else {
        Write-Host "[*] Git not found, downloading zip package..." -ForegroundColor Yellow
        $zipUrl = "https://github.com/chk-jxcn/minischeme-webrepl/archive/refs/heads/main.zip"
        $zipFile = "minischeme-webrepl.zip"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing
        Expand-Archive -Path $zipFile -DestinationPath "temp_webrepl" -Force
        Move-Item "temp_webrepl/minischeme-webrepl-main" $installDir
        Remove-Item "temp_webrepl", $zipFile -Recurse -Force
    }
} else {
    Write-Host "[*] Existing directory '$installDir' found. Updating..." -ForegroundColor Yellow
    if (Test-Path "$installDir/.git") {
        git -C $installDir pull
    }
}

Set-Location $installDir

# 3. Optional dependencies
Write-Host "[*] Checking Python dependencies..." -ForegroundColor Yellow
& $pythonCmd -m pip install --quiet pillow 2>$null

# 4. Launch Local WebREPL Server
$port = 8080
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "   MiniScheme WebREPL is ready! Starting local server...  " -ForegroundColor Green
Write-Host "   URL: http://localhost:$port                            " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""

# Open default browser
Start-Process "http://localhost:$port"

# Run server
& $pythonCmd server.py --port $port
