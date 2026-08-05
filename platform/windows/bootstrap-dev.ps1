# assemblrr Dev Bootstrap
# Copies local project files to WSL2 and runs setup.sh
# Alternative to bootstrap.ps1 — skips git clone, uses local files instead
# Usage:
#   .\bootstrap-dev.ps1              Show help
#   .\bootstrap-dev.ps1 -Full        Full setup (copy files + run setup.sh)
#   .\bootstrap-dev.ps1 -Full -Clean Uninstall first, then full setup
#   .\bootstrap-dev.ps1 -Update      Only copy updated files to WSL2
#   .\bootstrap-dev.ps1 -Exec <cmd>  Run an assemblrr CLI command in WSL2
#   .\bootstrap-dev.ps1 -Help        Show this help screen

[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$Full,
    [switch]$Clean,
    [switch]$Update,
    [string]$Exec
)

$ErrorActionPreference = "Stop"

$ProjectDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$AppName = "assemblrr"

function Show-Help {
    Write-Host ""
    Write-Host "assemblrr Dev Bootstrap" -ForegroundColor Cyan
    Write-Host "========================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Copies local project files to WSL2 for development." -ForegroundColor White
    Write-Host "Alternative to bootstrap.ps1 - skips git clone, uses local files instead." -ForegroundColor White
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\bootstrap-dev.ps1              Show this help screen"
    Write-Host "  .\bootstrap-dev.ps1 -Full        Full setup: copy files to WSL2 and run setup.sh"
    Write-Host "  .\bootstrap-dev.ps1 -Full -Clean Uninstall first, then full setup"
    Write-Host "  .\bootstrap-dev.ps1 -Update      Quick update: only copy changed files to WSL2"
    Write-Host "  .\bootstrap-dev.ps1 -Exec <cmd>  Run an assemblrr CLI command in WSL2"
    Write-Host "  .\bootstrap-dev.ps1 -Help        Show this help screen"
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  -Full     Copy project files to WSL2 and launch setup.sh"
    Write-Host "  -Clean    Uninstall existing installation (use with -Full for clean reinstall)"
    Write-Host "  -Update   Copy project files to WSL2 without running setup.sh"
    Write-Host "            Use this when you made changes on Windows that need to be"
    Write-Host "            reflected in the WSL2 environment"
    Write-Host "  -Exec     Run an assemblrr CLI command in WSL2 (e.g. -Exec 'uninstall -f')"
    Write-Host "            Requires an existing installation; runs with full TTY support"
    Write-Host "  -Help     Show this help screen"
    Write-Host ""
}

function Find-WSL2Distro {
    $distro = ""
    try {
        $guid = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss").DefaultDistribution
        $distro = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\$guid").DistributionName
    } catch {
        $output = wsl --list --verbose 2>$null
        $line = $output | Where-Object { $_ -match '^\*' }
        if ($line) {
            $distro = ($line -replace '^\*\s+', '' -replace '\s+.*', '').Trim()
            $distro = $distro -replace "^\xEF\xBB\xBF", ""
        }
    }
    return $distro
}



function Copy-ProjectToWSL2 {
    param([string]$Distro)
    if (-not $AppName) {
        Write-Host "App name is empty, aborting." -ForegroundColor Red
        exit 1
    }

    Write-Host "Copying project to WSL2 /tmp/$AppName..." -ForegroundColor Yellow
    # Safety check: refuse to remove if path is a symlink (prevents TOCTOU race condition)
    wsl -d $Distro -- bash -c "if [ -L /tmp/$AppName ]; then echo 'Refusing to remove symlink at /tmp/$AppName' >&2; exit 1; fi; rm -rf /tmp/$AppName 2>/dev/null; mkdir -p /tmp/$AppName"

    $driveLetter = $ProjectDir.Substring(0,1).ToLower()
    $wslSourcePath = "/mnt/$driveLetter" + ($ProjectDir.Substring(2) -replace '\\', '/')
    wsl -d $Distro -- bash -c "cp -r $wslSourcePath/* /tmp/$AppName/ && cp -r $wslSourcePath/.env.example $wslSourcePath/.gitignore /tmp/$AppName/ 2>/dev/null; true"

    wsl -d $Distro -- bash -c "chmod +x /tmp/$AppName/bin/setup.sh /tmp/$AppName/bin/cli.sh /tmp/$AppName/bin/docker-install.sh /tmp/$AppName/bin/configure.sh /tmp/$AppName/lib/*.sh /tmp/$AppName/scripts/*.sh 2>/dev/null"

    # Convert CRLF to LF on shell scripts (Windows line endings break bash)
    wsl -d $Distro -- bash -c "sed -i 's/\r$//' /tmp/$AppName/bin/*.sh /tmp/$AppName/lib/*.sh /tmp/$AppName/branding.conf /tmp/$AppName/compose/*.yaml /tmp/$AppName/compose/examples/*.yaml /tmp/$AppName/templates/*.env /tmp/$AppName/templates/*.yml /tmp/$AppName/scripts/*.sh 2>/dev/null; true"
    Write-Host "Files copied successfully." -ForegroundColor Green
}

function Test-InstallConfigExists {
    param([string]$Distro)
    $result = wsl -d $Distro -- bash -c "cat /opt/$AppName/.$AppName-config `$HOME/$AppName/.$AppName-config `$HOME/.$AppName-config 2>/dev/null | grep INSTALL_DIRECTORY"
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

install_dir="`$HOME/$AppName"
media_dir="`$HOME/$AppName-media"
cli_path="`$HOME/.local/bin/$AppName"
system_cli="/usr/local/bin/$AppName"

for dir in "`$install_dir" "`$media_dir"; do
    case "`$dir" in
        "`$HOME/$AppName"|"`$HOME/$AppName-media") ;;
        *) echo "Refusing unexpected cleanup path: `$dir" >&2; exit 1 ;;
    esac

    if [ -e "`$dir" ]; then
        safe_rm_rf "`$dir"
    fi
done

rm -f "`$cli_path" 2>/dev/null || true
rm -f "`$system_cli" 2>/dev/null || true
"@

    $cleanupScriptBytes = [System.Text.Encoding]::UTF8.GetBytes($cleanupScript)
    $cleanupScriptBase64 = [Convert]::ToBase64String($cleanupScriptBytes)
    $remoteCleanupScript = "/tmp/$AppName-cleanup-residue.sh"
    wsl -d $Distro -- bash -c "printf '%s' '$cleanupScriptBase64' | base64 -d | sed 's/\r$//' > '$remoteCleanupScript' && bash '$remoteCleanupScript'; status=`$?; rm -f '$remoteCleanupScript'; exit `$status"
}

function Invoke-Uninstall {
    param([string]$Distro, [switch]$ContinueOnError)
    if (-not (Test-InstallationExists -Distro $Distro)) {
        Write-Host "No existing installation to clean." -ForegroundColor Yellow
        return
    }

    if (-not (Test-InstallConfigExists -Distro $Distro)) {
        Invoke-ResidueCleanup -Distro $Distro
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Residue cleanup failed." -ForegroundColor Red
            exit 1
        }
        Write-Host "Residue cleanup complete." -ForegroundColor Green
        return
    }

    Write-Host "Uninstalling existing installation..." -ForegroundColor Yellow
    wsl -d $Distro -- bash -c "source /tmp/$AppName/branding.conf && bash /tmp/$AppName/bin/cli.sh uninstall -f"
    if ($LASTEXITCODE -ne 0) {
        if ($ContinueOnError -and -not (Test-InstallationExists -Distro $Distro)) {
            Write-Host "Uninstall reported an error, but no installation files remain. Continuing..." -ForegroundColor Yellow
        } else {
            Write-Host "Uninstall failed." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "Uninstall complete." -ForegroundColor Green
    }
}

# No parameters or -Help → show help
if (-not $Full -and -not $Clean -and -not $Update -and -not $Exec -or $Help) {
    Show-Help
    exit 0
}

# Detect WSL2 distro
$defaultDistro = Find-WSL2Distro
if (-not $defaultDistro) {
    Write-Host "No WSL2 distro found." -ForegroundColor Red
    exit 1
}
Write-Host "Using WSL2 distro: $defaultDistro" -ForegroundColor Cyan



# -Clean standalone: copy files first (need CLI for uninstall), then uninstall and exit
if ($Clean -and -not $Full) {
    Copy-ProjectToWSL2 -Distro $defaultDistro
    Invoke-Uninstall -Distro $defaultDistro
    exit 0
}

# -Update/-Exec: verify installation exists before doing anything
if ($Update -or $Exec) {
    if (-not (Test-InstallationExists -Distro $defaultDistro)) {
        Write-Host "No existing installation found. Run -Full first to set up." -ForegroundColor Red
        exit 1
    }
}

# Copy project files to WSL2 (skip for -Exec — CLI is already installed)
if (-not $Exec) {
    Copy-ProjectToWSL2 -Distro $defaultDistro
}

# -Full: also run setup.sh
if ($Full) {
    # -Clean: uninstall existing installation first
    # Use CLI from /tmp (just copied) — installed CLI may be missing/broken
    if ($Clean) {
        Invoke-Uninstall -Distro $defaultDistro -ContinueOnError
        Write-Host ""
    }

    Write-Host "Launching setup.sh in WSL2..." -ForegroundColor Green
    Write-Host ""

    # Run wsl directly in the current terminal — inherits ConPTY for full TTY/fzf support
    wsl -d $defaultDistro -- bash -i -c "cd /tmp/$AppName && bash bin/setup.sh"
}

# -Update: sync files to install directory and reinstall CLI
if ($Update) {
    Write-Host "Syncing updated files to install directory..." -ForegroundColor Yellow
    $updateScript = @"
#!/bin/bash
source /tmp/$AppName/branding.conf
INSTALL_DIR=""
for cfg in "/opt/`$APP_NAME/.`$APP_NAME-config" "`$HOME/`$APP_NAME/.`$APP_NAME-config" "`$HOME/.`$APP_NAME-config"; do
    if [ -f "`$cfg" ]; then
        INSTALL_DIR=`$(grep INSTALL_DIRECTORY "`$cfg" | cut -d= -f2 | tr -d '"' | tr -d "'")
        break
    fi
done
if [ -z "`$INSTALL_DIR" ]; then
    echo "No existing installation found. Run -Full first to set up." >&2
    exit 1
fi
echo "Install directory: `$INSTALL_DIR"
cp /tmp/$AppName/bin/cli.sh /tmp/$AppName/bin/setup.sh /tmp/$AppName/bin/docker-install.sh /tmp/$AppName/bin/configure.sh /tmp/$AppName/branding.conf "`$INSTALL_DIR/"
mkdir -p "`$INSTALL_DIR/lib"
cp /tmp/$AppName/lib/*.sh "`$INSTALL_DIR/lib/"
cp /tmp/$AppName/compose/base.yaml /tmp/$AppName/compose/vpn.yaml /tmp/$AppName/compose/direct-access.yaml "`$INSTALL_DIR/compose/"
mkdir -p "`$INSTALL_DIR/compose/examples"
cp /tmp/$AppName/compose/examples/custom.yaml.example "`$INSTALL_DIR/compose/examples/" 2>/dev/null || true
cp /tmp/$AppName/.env.example "`$INSTALL_DIR/" 2>/dev/null || true
cp /tmp/$AppName/templates/recyclarr-full_hd.yml /tmp/$AppName/templates/recyclarr-ultra_hd.yml "`$INSTALL_DIR/templates/"
mkdir -p "`$INSTALL_DIR/scripts"
cp /tmp/$AppName/scripts/* "`$INSTALL_DIR/scripts/"
echo "Files synced to install directory"
mkdir -p "`$HOME/.local/bin/lib"
cp "`$INSTALL_DIR/lib/"*.sh "`$HOME/.local/bin/lib/"
cp "`$INSTALL_DIR/cli.sh" "`$HOME/.local/bin/`$APP_CLI_NAME" && chmod +x "`$HOME/.local/bin/`$APP_CLI_NAME"
rm -f "/usr/local/bin/`$APP_CLI_NAME" 2>/dev/null || true
echo "CLI reinstalled to `$HOME/.local/bin/`$APP_CLI_NAME"
"@
    $updateScript | wsl -d $defaultDistro -- bash -c "sed 's/\r$//' | bash"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Update failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "Update complete." -ForegroundColor Green
}

# -Exec: run an assemblrr CLI command in WSL2
if ($Exec) {
    Write-Host "Running assemblrr $Exec in WSL2..." -ForegroundColor Green
    Write-Host ""

    # Run wsl directly in the current terminal — inherits ConPTY for full TTY/fzf support
    # bash -l sources .profile (which has PATH set by install_cli)
    wsl -d $defaultDistro -- bash -l -c "$AppName $Exec"
}
