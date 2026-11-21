# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Dev Bootstrap
# Copies local project files to WSL2 and runs setup.sh / update / exec

[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$Full,
    [switch]$Clean,
    [switch]$Update,
    [string]$Exec
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"

$ProjectDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$AppName = "assemblrr"

function Show-Help {
    Write-Host ""
    Write-Host "assemblrr Dev Bootstrap" -ForegroundColor Cyan
    Write-Host "========================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\bootstrap-dev.ps1              Show this help screen"
    Write-Host "  .\bootstrap-dev.ps1 -Full        Full setup: copy files to WSL2 and run setup.sh"
    Write-Host "  .\bootstrap-dev.ps1 -Full -Clean Uninstall first, then full setup"
    Write-Host "  .\bootstrap-dev.ps1 -Update      Sync managed files into WSL2 install"
    Write-Host "  .\bootstrap-dev.ps1 -Exec <cmd>  Run an assemblrr CLI command in WSL2"
    Write-Host "  .\bootstrap-dev.ps1 -Help        Show this help screen"
    Write-Host ""
}

function Find-WSL2Distro {
    try {
        $guid = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss").DefaultDistribution
        $distro = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\$guid").DistributionName
        if ($distro -and $distro -notin @("docker-desktop", "docker-desktop-data")) {
            return $distro
        }
    } catch { }

    $output = wsl --list --quiet 2>$null
    foreach ($rawLine in $output) {
        $candidate = ($rawLine -replace "\x00", "" -replace "^\xEF\xBB\xBF", "").Trim()
        if ($candidate -and $candidate -notin @("docker-desktop", "docker-desktop-data")) {
            return $candidate
        }
    }
    return ""
}

function Copy-ProjectToWSL2 {
    param([string]$Distro)
    if (-not $AppName) {
        Write-Host "App name is empty, aborting." -ForegroundColor Red
        exit 1
    }

    Write-Host "Copying project to WSL2 /tmp/$AppName..." -ForegroundColor Yellow
    wsl -d $Distro -- bash -c "if [ -L '/tmp/$AppName' ]; then echo 'Refusing symlink' >&2; exit 1; fi; rm -rf '/tmp/$AppName' 2>/dev/null; mkdir -p '/tmp/$AppName'"

    $driveLetter = $ProjectDir.Substring(0, 1).ToLower()
    $wslSourcePath = "/mnt/$driveLetter" + ($ProjectDir.Substring(2) -replace '\\', '/')
    $quotedSrc = "'" + ($wslSourcePath -replace "'", "'\"'\"'") + "'"
    wsl -d $Distro -- bash -c "cp -r $quotedSrc/. '/tmp/$AppName/' 2>/dev/null || true"

    wsl -d $Distro -- bash -c "chmod +x /tmp/$AppName/bin/*.sh /tmp/$AppName/lib/*.sh /tmp/$AppName/scripts/*.sh /tmp/$AppName/migrations/*.sh 2>/dev/null || true"
    wsl -d $Distro -- bash -c "find /tmp/$AppName -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name '*.yml' -o -name '*.conf' -o -name '.env.example' -o -name 'Dockerfile' -o -name '*.Dockerfile' \) -exec sed -i 's/\r$//' {} + 2>/dev/null; true"
    Write-Host "Files copied successfully." -ForegroundColor Green
}

function Test-InstallConfigExists {
    param([string]$Distro)
    $result = wsl -d $Distro -- bash -c "cat `$HOME/.$AppName-config /opt/$AppName/.$AppName-config `$HOME/$AppName/.$AppName-config 2>/dev/null | grep INSTALL_DIRECTORY"
    return (-not [string]::IsNullOrWhiteSpace($result))
}

function Test-InstallationResidueExists {
    param([string]$Distro)
    $result = wsl -d $Distro -- bash -c "[ -e `"`$HOME/$AppName`" ] || [ -e `"`$HOME/$AppName-media`" ] || [ -e `"`$HOME/.local/bin/$AppName`" ] && echo found"
    return ($result -match "found")
}

function Test-InstallationExists {
    param([string]$Distro)
    return ((Test-InstallConfigExists -Distro $Distro) -or (Test-InstallationResidueExists -Distro $Distro))
}

function Invoke-ResidueCleanup {
    param([string]$Distro)
    Write-Host "Partial installation detected without runtime config. Cleaning known WSL2 dev paths..." -ForegroundColor Yellow
    $cleanupScript = @"
set -euo pipefail
source /tmp/$AppName/lib/core.sh
for dir in "`$HOME/$AppName" "`$HOME/$AppName-media"; do
    [ -e "`$dir" ] && safe_rm_rf "`$dir"
done
rm -f "`$HOME/.local/bin/$AppName" "/usr/local/bin/$AppName" 2>/dev/null || true
"@
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cleanupScript))
    wsl -d $Distro -- bash -c "printf '%s' '$b64' | base64 -d | sed 's/\r$//' | bash"
}

function Invoke-Uninstall {
    param([string]$Distro, [switch]$ContinueOnError)
    if (-not (Test-InstallationExists -Distro $Distro)) {
        Write-Host "No existing installation to clean." -ForegroundColor Yellow
        return
    }
    if (-not (Test-InstallConfigExists -Distro $Distro)) {
        Invoke-ResidueCleanup -Distro $Distro
        if ($LASTEXITCODE -ne 0) { exit 1 }
        return
    }
    Write-Host "Uninstalling existing installation..." -ForegroundColor Yellow
    wsl -d $Distro -- bash -c "source /tmp/$AppName/branding.conf && bash /tmp/$AppName/bin/cli.sh uninstall -f"
    if ($LASTEXITCODE -ne 0) {
        if (-not $ContinueOnError -or (Test-InstallationExists -Distro $Distro)) {
            Write-Host "Uninstall failed." -ForegroundColor Red
            exit 1
        }
    }
}

if (-not $Full -and -not $Clean -and -not $Update -and -not $Exec -or $Help) {
    Show-Help
    exit 0
}

$defaultDistro = Find-WSL2Distro
if (-not $defaultDistro) {
    Write-Host "No usable WSL2 distro found." -ForegroundColor Red
    exit 1
}
Write-Host "Using WSL2 distro: $defaultDistro" -ForegroundColor Cyan

if ($Clean -and -not $Full) {
    Copy-ProjectToWSL2 -Distro $defaultDistro
    Invoke-Uninstall -Distro $defaultDistro
    exit 0
}

if ($Update -or $Exec) {
    if (-not (Test-InstallationExists -Distro $defaultDistro)) {
        Write-Host "No existing installation found. Run -Full first to set up." -ForegroundColor Red
        exit 1
    }
}

if (-not $Exec) {
    Copy-ProjectToWSL2 -Distro $defaultDistro
}

if ($Full) {
    if ($Clean) {
        Invoke-Uninstall -Distro $defaultDistro -ContinueOnError
        Write-Host ""
    }
    Write-Host "Launching setup.sh in WSL2..." -ForegroundColor Green
    wsl -d $defaultDistro -- bash -i -c "cd '/tmp/$AppName' && bash bin/setup.sh"
    exit $LASTEXITCODE
}

if ($Update) {
    Write-Host "Syncing managed files into install directory via lib/managed_files.sh..." -ForegroundColor Yellow
    $updateScript = @"
set -euo pipefail
source /tmp/$AppName/lib/core.sh
source /tmp/$AppName/lib/branding.sh
source /tmp/$AppName/lib/compose.sh
source /tmp/$AppName/lib/managed_files.sh
source /tmp/$AppName/lib/upgrade.sh
load_branding /tmp/$AppName
INSTALL_DIR=`$(find_install_directory || true)
[ -n "`$INSTALL_DIR" ] || { echo "No existing installation found." >&2; exit 1; }
apply_managed_files /tmp/$AppName "`$INSTALL_DIR" 0
refresh_user_cli "`$INSTALL_DIR"
echo "Synced managed files to `$INSTALL_DIR and updated CLI wrapper"
"@
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($updateScript))
    wsl -d $defaultDistro -- bash -c "printf '%s' '$b64' | base64 -d | sed 's/\r$//' | bash"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Update failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "Update complete." -ForegroundColor Green
}

if ($Exec) {
    Write-Host "Running $AppName $Exec in WSL2..." -ForegroundColor Green
    wsl -d $defaultDistro -- bash -l -c "$AppName $Exec"
}
