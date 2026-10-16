# MiniScheme WebREPL One-Click Installer & Launcher for Windows (PowerShell)
# Usage:
#   irm https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   MiniScheme WebREPL - One-Click Installer (Windows)     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$installDir = Join-Path $HOME ".minischeme-webrepl"
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

$exePath = Join-Path $installDir "MiniScheme-WebREPL.exe"
$exeUrl = "https://github.com/chk-jxcn/minischeme-webrepl/releases/download/v1.0.0/MiniScheme-WebREPL.exe"

# 1. Try downloading standalone packaged MiniScheme-WebREPL.exe from GitHub Release
try {
    Write-Host "[*] Downloading standalone MiniScheme-WebREPL.exe from GitHub Release..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $exeUrl -OutFile $exePath -UseBasicParsing
    if ((Test-Path $exePath) -and ((Get-Item $exePath).Length -gt 100000)) {
        Write-Host "[+] Downloaded MiniScheme-WebREPL.exe to $exePath" -ForegroundColor Green
        Write-Host "[*] Starting MiniScheme-WebREPL.exe (Default port: 8087, System Tray enabled)..." -ForegroundColor Green
        Start-Process -FilePath $exePath
        exit 0
    }
} catch {
    Write-Host "[*] Standalone .exe not used ($($_.Exception.Message)), falling back to Python source mode..." -ForegroundColor Yellow
}

# 2. Fallback: Python source mode
$pythonCmd = $null
if (Get-Command python -ErrorAction SilentlyContinue) {
    $pythonCmd = "python"
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $pythonCmd = "py"
}

if (-not $pythonCmd) {
    Write-Host "[!] Error: Neither MiniScheme-WebREPL.exe nor Python 3 was available." -ForegroundColor Red
    exit 1
}

$repoDir = Join-Path $installDir "repo"
if (-not (Test-Path $repoDir)) {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git clone https://github.com/chk-jxcn/minischeme-webrepl.git $repoDir
    } else {
        $zipUrl = "https://github.com/chk-jxcn/minischeme-webrepl/archive/refs/heads/main.zip"
        $zipFile = Join-Path $installDir "webrepl.zip"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing
        Expand-Archive -Path $zipFile -DestinationPath $installDir -Force
        Move-Item (Join-Path $installDir "minischeme-webrepl-main") $repoDir -Force
        Remove-Item $zipFile -Force
    }
} else {
    if (Test-Path "$repoDir/.git") {
        git -C $repoDir pull
    }
}

Set-Location $repoDir
& $pythonCmd server.py --port 8087 --open-browser
