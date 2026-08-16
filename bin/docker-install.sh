#!/bin/bash
set -euo pipefail

# Docker installation helper — supports multiple distros
# Called by setup.sh when Docker is not found

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$SCRIPT_DIR"

# Source shared library (safe_source, logging, colors)
if [ -f "$SCRIPT_DIR/../lib/core.sh" ]; then
    APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    source "$APP_ROOT/lib/core.sh"
    source "$APP_ROOT/lib/branding.sh"
elif [ -f "$SCRIPT_DIR/lib/core.sh" ]; then
    source "$SCRIPT_DIR/lib/core.sh"
    source "$SCRIPT_DIR/lib/branding.sh"
else
    # Minimal fallback if lib modules are not available
    log_error() { echo -e "\033[0;31m$1\033[0m" >&2; exit 1; }
    log_info() { echo "$1"; }
    log_success() { echo -e "\033[0;32m$1\033[0m"; }
    load_branding() {
        APP_NAME="assemblrr"
        APP_DISPLAY_NAME="assemblrr"
        APP_CLI_NAME="assemblrr"
    }
fi

# Source branding — use load_branding for validation + fallback
load_branding "$APP_ROOT"

detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "$ID"
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
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "unknown")

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$distro_id/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro_id \
$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

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
    sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
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

    # Add user to docker group
    sudo usermod -aG docker "$USER"

    # Start Docker service
    sudo systemctl enable docker
    sudo systemctl start docker

    log_success "Docker installed successfully!"
    log_info "NOTE: You may need to log out and back in for group changes to take effect."
    log_info "Re-run the setup script after Docker is available."
    exit 0
}

main
