#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Docker installation helper — supports Ubuntu/Debian/derivatives, Arch, Fedora
# Called by setup.sh when Docker is not found
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$SCRIPT_DIR"

if [ -f "$SCRIPT_DIR/../lib/core.sh" ]; then
    APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck source=/dev/null
    source "$APP_ROOT/lib/core.sh"
    # shellcheck source=/dev/null
    source "$APP_ROOT/lib/branding.sh"
elif [ -f "$SCRIPT_DIR/lib/core.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/branding.sh"
else
    log_error() { echo -e "\033[0;31m$1\033[0m" >&2; exit 1; }
    log_info() { echo "$1"; }
    log_success() { echo -e "\033[0;32m$1\033[0m"; }
    load_branding() {
        APP_NAME="assemblrr"
        APP_DISPLAY_NAME="assemblrr"
        APP_CLI_NAME="assemblrr"
    }
fi

load_branding "$APP_ROOT"

detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    elif [ -f /etc/fedora-release ]; then
        echo "fedora"
    else
        echo "unknown"
    fi
}

install_docker_debian() {
    local distro_id="$1"
    local repo_distro="$distro_id"
    local codename=""

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    fi
    if [ -z "$codename" ]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "noble")
    fi

    # Linux Mint, Pop!_OS, and elementary OS track Ubuntu upstream repos on download.docker.com
    case "$distro_id" in
        linuxmint|pop|elementary) repo_distro="ubuntu" ;;
    esac

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$repo_distro/gpg" \
        | sudo gpg --yes --batch --dearmor -o /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$repo_distro $codename stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_arch() {
    echo
    echo "Arch Linux: about to run a full system upgrade (pacman -Syu)."
    echo "A partial install (-Sy without -u) can break packages (GLIBC mismatch)."
    echo
    sudo pacman -Syu --noconfirm --needed docker docker-compose
}

install_docker_fedora() {
    sudo dnf install -y dnf-plugins-core
    # Fedora 41+ uses DNF5 (`addrepo --from-repofile=...`); older releases use `--add-repo`.
    if ! sudo dnf config-manager addrepo --overwrite --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null; then
        sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    fi
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

main() {
    local distro
    distro=$(detect_distro)

    log_info "Detected distribution: $distro"

    case "$distro" in
        ubuntu|debian|linuxmint|pop|elementary)
            install_docker_debian "$distro"
            ;;
        arch|manjaro|endeavouros|garuda)
            install_docker_arch
            ;;
        fedora)
            install_docker_fedora
            ;;
        *)
            log_error "Unsupported distribution: $distro. Please install Docker manually from https://docs.docker.com/engine/install/"
            ;;
    esac

    sudo usermod -aG docker "$USER"

    if [ "$(ps -p 1 -o comm= 2>/dev/null || true)" = "systemd" ]; then
        sudo systemctl enable docker
        sudo systemctl start docker
    else
        log_info "Non-systemd environment detected — start dockerd or Docker Desktop manually if needed."
    fi

    log_success "Docker installed successfully!"
    log_info "NOTE: You may need to log out and back in for group changes to take effect."
    log_info "Re-run the setup script after Docker is available."
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
