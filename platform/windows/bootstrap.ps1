# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Windows Bootstrap
# Clones the repository, copies to WSL2, and launches setup.sh
#
# Usage:
#   irm https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/windows/bootstrap.ps1 | iex
#   $env:ASSEMBLRR_REF = "dev"; irm ... | iex
#   .\bootstrap.ps1 -Ref dev

param(
    [Parameter(Mandatory = $false)]
    [Alias("Branch")]
    [string]$Ref = ""
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"

$AppName = "assemblrr"
$RepoURL = "https://github.com/soulis-1256/assemblrr"

if (-not $Ref) {
    if ($env:ASSEMBLRR_REF) {
        $Ref = $env:ASSEMBLRR_REF
    } else {
        $Ref = "main"
    }
}

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    Write-Host "WSL2 is not installed." -ForegroundColor Red
    Write-Host "Please install Docker Desktop for Windows first: https://docs.docker.com/desktop/install/windows-install/" -ForegroundColor Yellow
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git for Windows is required to clone the repository." -ForegroundColor Red
    Write-Host "Install Git (https://git-scm.com/download/win) and re-run this script." -ForegroundColor Yellow
    exit 1
}

function Get-TargetWSLDistro {
    try {
        $defaultGuid = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss").DefaultDistribution
        $name = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\$defaultGuid").DistributionName
        if ($name -and $name -notin @("docker-desktop", "docker-desktop-data")) {
            return $name
        }
    } catch { }

    $wslOutput = wsl --list --quiet 2>$null
    foreach ($rawLine in $wslOutput) {
        $candidate = ($rawLine -replace "\x00", "" -replace "^\xEF\xBB\xBF", "").Trim()
        if ($candidate -and $candidate -notin @("docker-desktop", "docker-desktop-data")) {
            return $candidate
        }
    }
    return ""
}

$defaultDistro = Get-TargetWSLDistro
if (-not $defaultDistro) {
    Write-Host "No usable WSL2 Linux distribution found (excluding docker-desktop)." -ForegroundColor Red
    Write-Host "Install Ubuntu on WSL2 with: wsl --install -d Ubuntu" -ForegroundColor Yellow
    exit 1
}

Write-Host "Using WSL2 distro: $defaultDistro" -ForegroundColor Green
Write-Host ""

Write-Host "Cloning repository @ $Ref..." -ForegroundColor White
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("$AppName." + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
git clone --depth=1 --branch $Ref $RepoURL $tempDir 2>$null
if ($LASTEXITCODE -ne 0) {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    git clone --depth=1 $RepoURL $tempDir
    if ($LASTEXITCODE -eq 0) {
        git -C $tempDir fetch --depth=1 origin $Ref
        git -C $tempDir checkout -q FETCH_HEAD
    }
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to clone repository @ $Ref." -ForegroundColor Red
    exit 1
}
Write-Host "Repository cloned." -ForegroundColor Green
Write-Host ""

Write-Host "Copying project to WSL2..." -ForegroundColor White
wsl -d $defaultDistro -- bash -c "if [ -L '/tmp/$AppName' ]; then echo 'Refusing to remove symlink at /tmp/$AppName' >&2; exit 1; fi; rm -rf '/tmp/$AppName' 2>/dev/null; mkdir -p '/tmp/$AppName'"

$driveLetter = $tempDir.Substring(0, 1).ToLower()
$wslSourcePath = "/mnt/$driveLetter" + ($tempDir.Substring(2) -replace '\\', '/')
$quotedSrc = "'" + ($wslSourcePath -replace "'", "'\"'\"'") + "'"

wsl -d $defaultDistro -- bash -c "cp -r $quotedSrc/. '/tmp/$AppName/' 2>/dev/null || true"
wsl -d $defaultDistro -- bash -c "find /tmp/$AppName -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name '*.yml' -o -name '*.conf' -o -name '.env.example' -o -name 'Dockerfile' -o -name '*.Dockerfile' \) -exec sed -i 's/\r$//' {} + 2>/dev/null; true"
wsl -d $defaultDistro -- bash -c "chmod +x /tmp/$AppName/bin/*.sh /tmp/$AppName/lib/*.sh /tmp/$AppName/scripts/*.sh /tmp/$AppName/platform/linux/bootstrap.sh 2>/dev/null; true"

Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
Write-Host "Project files copied." -ForegroundColor Green
Write-Host ""

# Translate Windows backup file paths in --restore arguments into WSL /mnt/... paths
$translatedArgs = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -match '^[A-Za-z]:\\' -and (Test-Path $a)) {
        $drv = $a.Substring(0, 1).ToLower()
        $translatedArgs += "/mnt/$drv" + ($a.Substring(2) -replace '\\', '/')
    } else {
        $translatedArgs += $a
    }
}
$setupArgs = ($translatedArgs | ForEach-Object { "'" + ($_ -replace "'", "'\"'\"'") + "'" }) -join ' '

Write-Host "Launching ${AppName} setup in WSL2..." -ForegroundColor White
Write-Host ""
wsl -d $defaultDistro -- bash -i -c "cd '/tmp/$AppName' && ASSEMBLRR_INSTALL_REF='$Ref' bash bin/setup.sh $setupArgs"
$setupExit = $LASTEXITCODE
if ($setupExit -ne 0) {
    Write-Host ""
    Write-Host "Setup did not finish. The operator CLI may already be installed in WSL." -ForegroundColor Yellow
    Write-Host "  wsl -d $defaultDistro -- ~/.local/bin/$AppName status" -ForegroundColor Cyan
    Write-Host "  wsl -d $defaultDistro -- ~/.local/bin/$AppName uninstall" -ForegroundColor Cyan
}
exit $setupExit
