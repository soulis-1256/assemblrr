# assemblrr Windows Bootstrap
# Clones the repository, copies to WSL2, and launches setup.sh
#
# Usage:
#   irm https://raw.githubusercontent.com/soulis-1256/assemblrr/main/platform/windows/bootstrap.ps1 | iex
#   $env:ASSEMBLRR_REF = "dev"; irm ... | iex
#   .\bootstrap.ps1 -Ref dev
#
# Ref: -Ref / -Branch / $env:ASSEMBLRR_REF (default: main)

param(
    [Parameter(Mandatory = $false)]
    [Alias("Branch")]
    [string]$Ref = ""
)

$ErrorActionPreference = "Stop"

$AppName = "assemblrr"
$RepoURL = "https://github.com/soulis-1256/assemblrr"

if (-not $Ref) {
    if ($env:ASSEMBLRR_REF) {
        $Ref = $env:ASSEMBLRR_REF
    } else {
        $Ref = "main"
    }
}

# Step 1: Check WSL2 is available
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    Write-Host "WSL2 is not installed." -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install Docker Desktop for Windows first:" -ForegroundColor Yellow
    Write-Host "https://docs.docker.com/desktop/install/windows-install/" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Docker Desktop will set up WSL2 automatically." -ForegroundColor Yellow
    exit 1
}

# Step 2: Detect default WSL2 distro from Windows Registry
$defaultDistro = ""
try {
    $defaultGuid = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss").DefaultDistribution
    $defaultDistro = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\$defaultGuid").DistributionName
} catch {
    # Fallback: parse wsl --list --verbose output
    $wslOutput = wsl --list --verbose 2>$null
    $defaultLine = $wslOutput | Where-Object { $_ -match '^\*' }
    if ($defaultLine) {
        # Parse the * marker line: "* archlinux Running 2"
        $defaultDistro = ($defaultLine -replace '^\*\s+', '' -replace '\s+.*', '').Trim()
        # Strip BOM if present
        $defaultDistro = $defaultDistro -replace "^\xEF\xBB\xBF", ""
    }
}

if (-not $defaultDistro) {
    Write-Host "No WSL2 distribution found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install Docker Desktop for Windows first:" -ForegroundColor Yellow
    Write-Host "https://docs.docker.com/desktop/install/windows-install/" -ForegroundColor Cyan
    exit 1
}

Write-Host "Using WSL2 distro: $defaultDistro" -ForegroundColor Green
Write-Host ""

# Step 4: Clone repository to temporary Windows directory
Write-Host "Cloning repository @ $Ref..." -ForegroundColor White
$tempDir = [System.IO.Path]::GetTempPath() + $AppName + "." + [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
git clone --depth=1 --branch $Ref $RepoURL $tempDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to clone repository @ $Ref. Is git installed and is the ref valid?" -ForegroundColor Red
    exit 1
}
Write-Host "Repository cloned." -ForegroundColor Green
Write-Host ""

# Step 5: Copy project files to WSL2
Write-Host "Copying project to WSL2..." -ForegroundColor White
wsl -d $defaultDistro -- bash -c "if [ -L /tmp/$AppName ]; then echo 'Refusing to remove symlink at /tmp/$AppName' >&2; exit 1; fi; rm -rf /tmp/$AppName 2>/dev/null; mkdir -p /tmp/$AppName"

# Convert Windows path to WSL path
$wslSourcePath = $tempDir -replace '\\', '/'
$driveLetter = $tempDir.Substring(0,1).ToLower()
$wslSourcePath = "/mnt/$driveLetter" + ($tempDir.Substring(2) -replace '\\', '/')

wsl -d $defaultDistro -- bash -c "cp -r $wslSourcePath/* /tmp/$AppName/ && cp -r $wslSourcePath/.env.example $wslSourcePath/.gitignore /tmp/$AppName/ 2>/dev/null; true"

# Fix line endings and set permissions
wsl -d $defaultDistro -- bash -c "find /tmp/$AppName -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name '*.yml' -o -name '*.conf' -o -name '.env.example' -o -name 'Dockerfile' -o -name '*.Dockerfile' \) -exec sed -i 's/\r$//' {} + 2>/dev/null; true"
wsl -d $defaultDistro -- bash -c "chmod +x /tmp/$AppName/bin/*.sh /tmp/$AppName/lib/*.sh /tmp/$AppName/scripts/*.sh /tmp/$AppName/platform/linux/bootstrap.sh 2>/dev/null; true"

# Cleanup temp directory
Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue

Write-Host "Project files copied." -ForegroundColor Green
Write-Host ""

# Step 6: Launch setup.sh in WSL2
Write-Host "Launching ${AppName} setup in WSL2..." -ForegroundColor White
Write-Host ""

# Pass any PowerShell args through to setup.sh
$setupArgs = $args -join ' '
# Run wsl directly in the current terminal — inherits ConPTY for full TTY/fzf support
wsl -d $defaultDistro -- bash -i -c "cd /tmp/$AppName && bash bin/setup.sh $setupArgs"
$setupExit = $LASTEXITCODE
if ($setupExit -ne 0) {
    Write-Host ""
    Write-Host "Setup did not finish. The operator CLI may already be installed in WSL." -ForegroundColor Yellow
    Write-Host "From PowerShell:" -ForegroundColor White
    Write-Host "  wsl -d $defaultDistro -- ~/.local/bin/$AppName status" -ForegroundColor Cyan
    Write-Host "  wsl -d $defaultDistro -- ~/.local/bin/$AppName uninstall" -ForegroundColor Cyan
    Write-Host "Or open WSL and run those same commands there." -ForegroundColor White
    Write-Host ""
}
exit $setupExit
