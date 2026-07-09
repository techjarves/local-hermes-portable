param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$Url,
    [Parameter(Position=1, Mandatory=$true)]
    [string]$OutFile
)

$ErrorActionPreference = "Stop"

# Ensure output directory exists
$OutDir = Split-Path -Parent $OutFile
if ($OutDir -and -not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$fileName = Split-Path -Leaf $OutFile
Write-Host "Downloading $fileName..."

# Try to use curl.exe if available since it provides progress and handles redirects/SSL well
if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    Write-Host "Using curl.exe for download..."
    & curl.exe -L -f --ssl-no-revoke --retry 3 --retry-delay 2 --connect-timeout 30 -o $OutFile $Url
    if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) {
        Write-Host "Download successful via curl."
        exit 0
    }
    Write-Warning "curl failed or downloaded 0 bytes. Falling back to PowerShell web methods..."
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
}

# Fallback: Setup TLS configuration
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Try Invoke-WebRequest with basic parsing
try {
    Write-Host "Using Invoke-WebRequest..."
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
    if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) {
        Write-Host "Download successful via Invoke-WebRequest."
        exit 0
    }
} catch {
    Write-Warning "Invoke-WebRequest failed: $_"
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
}

# Try System.Net.WebClient
try {
    Write-Host "Using System.Net.WebClient..."
    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($Url, $OutFile)
    if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) {
        Write-Host "Download successful via WebClient."
        exit 0
    }
} catch {
    Write-Error "WebClient failed: $_"
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
}

Write-Error "Failed to download $Url to $OutFile"
exit 1
