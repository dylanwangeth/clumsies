$ErrorActionPreference = "Stop"

$Repo = "lilhammerfun/clumsies"
$InstallDir = Join-Path $env:USERPROFILE ".clumsies"
$BinDir = Join-Path $InstallDir "bin"
$BinaryName = "clumsies-windows-x86_64.exe"

function Info($msg) { Write-Host "-> $msg" }
function Success($msg) { Write-Host "OK $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "Error: $msg" -ForegroundColor Red; exit 1 }

Write-Host "Installing clumsies..." -ForegroundColor White

# Create install directory
Info "Creating $BinDir"
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

# Download checksums
Info "Downloading checksums..."
$ChecksumsUrl = "https://github.com/$Repo/releases/latest/download/checksums.txt"
$ChecksumsFile = Join-Path ([System.IO.Path]::GetTempPath()) "clumsies-checksums.txt"
Invoke-WebRequest -Uri $ChecksumsUrl -OutFile $ChecksumsFile -UseBasicParsing

$ExpectedLine = Get-Content $ChecksumsFile | Where-Object { $_ -match $BinaryName }
Remove-Item $ChecksumsFile -ErrorAction SilentlyContinue
if (-not $ExpectedLine) { Fail "Checksum not found for $BinaryName" }
$ExpectedChecksum = ($ExpectedLine -split '\s+')[0]

# Download binary
Info "Downloading binary..."
$DownloadUrl = "https://github.com/$Repo/releases/latest/download/$BinaryName"
$TempBinary = Join-Path ([System.IO.Path]::GetTempPath()) "clumsies-download.exe"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempBinary -UseBasicParsing

# Verify checksum
Info "Verifying checksum..."
$ActualChecksum = (Get-FileHash -Path $TempBinary -Algorithm SHA256).Hash.ToLower()
if ($ActualChecksum -ne $ExpectedChecksum) {
    Remove-Item $TempBinary -ErrorAction SilentlyContinue
    Fail "Checksum verification failed!"
}
Success "Checksum verified"

# Install binary
$DestPath = Join-Path $BinDir "clumsies.exe"
Move-Item -Path $TempBinary -Destination $DestPath -Force

# Add to PATH
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$BinDir*") {
    Info "Adding $BinDir to user PATH"
    [Environment]::SetEnvironmentVariable("Path", "$BinDir;$UserPath", "User")
} else {
    Info "PATH already configured"
}

Success "clumsies installed successfully!"
Write-Host "Restart your terminal, then try:"
Write-Host "    clumsies --help" -ForegroundColor Cyan
Write-Host "    clumsies login --server-url http://127.0.0.1:8400 --username admin" -ForegroundColor Cyan
Write-Host "    clumsies adapt" -ForegroundColor Cyan
