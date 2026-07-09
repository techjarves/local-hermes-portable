# ============================================================================
# Hermes Portable - Reset Script (Windows)
# ============================================================================
# Deletes downloaded runtimes and source code to trigger fresh first-run setup.
#
# Usage:
#   .\scripts\reset-windows.ps1 -Mode soft    # Keep data/ folder (API keys, config)
#   .\scripts\reset-windows.ps1 -Mode full    # Delete everything including data/
# ============================================================================

param(
    [ValidateSet("soft", "full")]
    [string]$Mode = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent

# If no mode provided, ask interactively
if (-not $Mode) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "   Hermes Portable - Reset" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Choose reset mode:" -ForegroundColor Yellow
    Write-Host "  [1] Soft reset  - Delete runtimes + source, keep data/ (API keys, config, history)"
    Write-Host "  [2] Full reset  - Delete everything including data/ (completely fresh start)"
    Write-Host ""
    $choice = Read-Host "Enter 1 or 2"
    if ($choice -eq "2") {
        $Mode = "full"
    } else {
        $Mode = "soft"
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Hermes Portable - Reset ($Mode)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Stop any running gateway first
$lockFile = Join-Path $Root "data\auth.lock"
if (Test-Path $lockFile) {
    Write-Host "[INFO]  Stopping gateway (removing lock) ..." -ForegroundColor Yellow
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

# Also try to kill any hermes gateway processes
Get-Process | Where-Object { $_.ProcessName -like "*python*" -or $_.ProcessName -like "*hermes*" } | ForEach-Object {
    try {
        $cmd = (Get-WmiObject Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
        if ($cmd -and $cmd -like "*hermes*gateway*") {
            Write-Host "[INFO]  Killing gateway process PID $($_.Id) ..." -ForegroundColor Yellow
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# --- Soft reset: delete runtimes + source, keep data ---
$foldersToDelete = @()

$runtimes = Join-Path $Root ".cache\runtimes"
if (Test-Path $runtimes) {
    $foldersToDelete += $runtimes
}

$src = Join-Path $Root "src\hermes-agent"
if (Test-Path $src) {
    $foldersToDelete += $src
}

# --- Full reset: also delete data ---
if ($Mode -eq "full") {
    $data = Join-Path $Root "data"
    if (Test-Path $data) {
        $foldersToDelete += $data
    }
    $cache = Join-Path $Root ".cache"
    if (Test-Path $cache) {
        $foldersToDelete += $cache
    }
}

# Confirm before deleting
Write-Host ""
Write-Host "The following folders will be DELETED:" -ForegroundColor Yellow
foreach ($f in $foldersToDelete) {
    $size = 0
    if (Test-Path $f) {
        $size = [math]::Round((Get-ChildItem $f -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    }
    Write-Host "  - $f ($size MB)" -ForegroundColor Red
}

if ($Mode -eq "soft") {
    Write-Host ""
    Write-Host "Your data folder is PRESERVED:" -ForegroundColor Green
    Write-Host "  - $Root\data\.env        (API keys)"
    Write-Host "  - $Root\data\config.yaml  (settings)"
    Write-Host "  - $Root\data\sessions\    (chat history)"
}

Write-Host ""
$confirm = Read-Host "Type 'yes' to confirm deletion"
if ($confirm -ne "yes") {
    Write-Host "Cancelled. Nothing was deleted." -ForegroundColor Yellow
    exit 0
}

# Perform deletion
foreach ($f in $foldersToDelete) {
    if (Test-Path $f) {
        Write-Host "[DEL]   $f ..." -NoNewline
        Remove-Item $f -Recurse -Force
        Write-Host " done" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Reset Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

if ($Mode -eq "soft") {
    Write-Host ""
    Write-Host "Next step: run .\launch.bat to re-download runtimes"
    Write-Host "Your API keys and config are still saved in data\"
} else {
    Write-Host ""
    Write-Host "Next step: run .\launch.bat for a completely fresh start"
    Write-Host "You'll need to re-run the setup wizard and re-enter API keys"
}
