#!/bin/bash
# SinkSonic — one-liner setup
#   curl -sSL https://raw.githubusercontent.com/SHU-red/sinksonic/main/scripts/setup.sh | sudo bash
#
# Installs PipeWire, WirePlumber, Docker, and starts SinkSonic.
# Works on: Raspberry Pi OS, Debian, Ubuntu, Fedora, Arch, Alpine

set -euo pipefail

# ── Utilities ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }

# ── Config ────────────────────────────────────────────────────────────────────
SINKSONIC_USER="${SINKSONIC_USER:-sinksonic}"
DATA_DIR="${DATA_DIR:-/data}"
DOCKER_COMPOSE_DIR="${DOCKER_COMPOSE_DIR:-/opt/sinksonic}"
LISTEN_PORT="${LISTEN_PORT:-4713}"
DRY_RUN="${DRY_RUN:-}"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --user) SINKSONIC_USER="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --port) LISTEN_PORT="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--dry-run] [--user sinksonic] [--data-dir /data] [--port 4713]"; exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_LIKE="$ID_LIKE"
    elif command -v apk >/dev/null 2>&1; then
        OS_ID="alpine"
    else
        err "Cannot detect OS. Please install manually."
        exit 1
    fi
    info "Detected OS: $OS_ID"
}

# ── Install packages ──────────────────────────────────────────────────────────
install_packages() {
    local pkgs_pipewire pkgs_docker

    case "$OS_ID" in
        debian|ubuntu|raspbian|linuxmint|pop)
            pkgs_pipewire="pipewire pipewire-pulse wireplumber pulseaudio-utils avahi-daemon qpwgraph"
            pkgs_docker="docker.io docker-compose-v2"
            # On Pi, also install firmware for audio
            if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "armv7l" ]; then
                pkgs_pipewire="$pkgs_pipewire raspberrypi-kernel"
            fi
            CMD_UPDATE="apt-get update -qq"
            CMD_INSTALL="apt-get install -y -qq"
            ;;
        fedora|centos|rhel|rocky|alma)
            pkgs_pipewire="pipewire pipewire-pulseaudio wireplumber pulseaudio-utils avahi qpwgraph"
            pkgs_docker="docker docker-compose"
            CMD_UPDATE="dnf check-update -q || true"
            CMD_INSTALL="dnf install -y"
            ;;
        arch|manjaro|endeavour)
            pkgs_pipewire="pipewire pipewire-pulse wireplumber libpulse avahi qpwgraph"
            pkgs_docker="docker docker-compose"
            CMD_UPDATE="pacman -Sy --noconfirm"
            CMD_INSTALL="pacman -S --noconfirm"
            ;;
        alpine)
            pkgs_pipewire="pipewire wireplumber pulseaudio-utils avahi"
            pkgs_docker="docker docker-compose"
            CMD_UPDATE="apk update -q"
            CMD_INSTALL="apk add"
            ;;
        *)
            warn "Unrecognized OS: $OS_ID. Attempting apt-based install..."
            pkgs_pipewire="pipewire pipewire-pulse wireplumber pulseaudio-utils avahi-daemon"
            pkgs_docker="docker.io docker-compose-v2"
            CMD_UPDATE="apt-get update -qq 2>/dev/null || true"
            CMD_INSTALL="apt-get install -y -qq"
            ;;
    esac

    dry_run_hint "$CMD_UPDATE && $CMD_INSTALL $pkgs_pipewire $pkgs_docker"
    if [ -z "$DRY_RUN" ]; then
        info "Updating package lists..."
        eval "$CMD_UPDATE" >/dev/null 2>&1 || true
        info "Installing PipeWire + Docker..."
        eval "$CMD_INSTALL $pkgs_pipewire" || warn "PipeWire install had issues (may already be installed)"
        eval "$CMD_INSTALL $pkgs_docker" || warn "Docker install had issues (may already be installed)"
    fi
}

# ── Enable services ───────────────────────────────────────────────────────────
enable_services() {
    dry_run_hint "systemctl enable --now pipewire-pulse wireplumber avahi-daemon docker"
    if [ -z "$DRY_RUN" ]; then
        # Enable system-level PipeWire services
        systemctl enable --now pipewire-pulse 2>/dev/null || warn "pipewire-pulse service not found (may be socket-activated)"
        systemctl enable --now wireplumber 2>/dev/null || warn "wireplumber service not found"
        systemctl enable --now avahi-daemon 2>/dev/null || warn "avahi-daemon not found"
        systemctl enable --now docker 2>/dev/null || warn "docker service not found"
    fi
}

# ── Configure PipeWire TCP ─────────────────────────────────────────────────────
configure_pipewire_tcp() {
    local conf_dir="/etc/pipewire/pipewire-pulse.conf.d"
    local conf_file="$conf_dir/10-network-tcp.conf"
    local script_dir="$(dirname "$0")"

    dry_run_hint "mkdir -p $conf_dir && cp pipewire/10-network-tcp.conf $conf_file"
    if [ -z "$DRY_RUN" ]; then
        mkdir -p "$conf_dir"
        if [ -f "$script_dir/pipewire/10-network-tcp.conf" ]; then
            cp "$script_dir/pipewire/10-network-tcp.conf" "$conf_file"
        else
            # Fallback: write inline
            cat > "$conf_file" << 'CONF'
pulse.cmd = [
    {   cmd = "load-module"
        args = "module-native-protocol-tcp auth-anonymous=true"
        flags = [ nofail ]
    }
]
pulse.properties = {
    pulse.idle.timeout = 0
}
stream.properties = {
    resample.quality = 14
}
CONF
        fi
        chmod 644 "$conf_file"
        info "PipeWire TCP config installed: $conf_file"
    fi
}

# ── Create sinksonic user ──────────────────────────────────────────────────────
create_user() {
    dry_run_hint "useradd -m -G audio,pipewire,video $SINKSONIC_USER"
    if [ -z "$DRY_RUN" ]; then
        if ! id "$SINKSONIC_USER" &>/dev/null; then
            useradd -m -G audio,pipewire,video "$SINKSONIC_USER" 2>/dev/null || \
            useradd -m -G audio,video "$SINKSONIC_USER"
            info "User '$SINKSONIC_USER' created"
        else
            info "User '$SINKSONIC_USER' already exists"
            usermod -aG audio,pipewire,video "$SINKSONIC_USER" 2>/dev/null || true
        fi
        # Enable linger so user services start at boot
        loginctl enable-linger "$SINKSONIC_USER" 2>/dev/null || true
    fi
}

# ── Set up data directory ──────────────────────────────────────────────────────
setup_data_dir() {
    dry_run_hint "mkdir -p $DATA_DIR && chown $SINKSONIC_USER $DATA_DIR"
    if [ -z "$DRY_RUN" ]; then
        mkdir -p "$DATA_DIR"
        chown "$SINKSONIC_USER" "$DATA_DIR"
        info "Data directory: $DATA_DIR"
    fi
}

# ── Deploy docker-compose ─────────────────────────────────────────────────────
deploy_docker() {
    dry_run_hint "mkdir -p $DOCKER_COMPOSE_DIR && cp docker-compose.yml $DOCKER_COMPOSE_DIR/ && docker compose up -d"
    if [ -z "$DRY_RUN" ]; then
        mkdir -p "$DOCKER_COMPOSE_DIR"
        # Copy compose file from script dir or download from GitHub
        local script_dir="$(dirname "$0")"
        if [ -f "$script_dir/../docker-compose.yml" ]; then
            cp "$script_dir/../docker-compose.yml" "$DOCKER_COMPOSE_DIR/"
            cp "$script_dir/../Dockerfile" "$DOCKER_COMPOSE_DIR/" 2>/dev/null || true
            cp -r "$script_dir/../webui" "$DOCKER_COMPOSE_DIR/" 2>/dev/null || true
        else
            # Download from GitHub
            if command -v docker &>/dev/null; then
                docker pull ghcr.io/shu-red/sinksonic-webui:latest 2>/dev/null || \
                warn "Pre-built image not available; building from source"
            fi
        fi
        cd "$DOCKER_COMPOSE_DIR"
        docker compose up -d 2>&1 || warn "docker compose failed — is Docker running?"
        info "SinkSonic container started"
    fi
}

# ── Enable read-only root (SD card longevity) ─────────────────────────────────
enable_readonly_root() {
    dry_run_hint "Enable read-only root filesystem (overlay)"

    if [ "$OS_ID" = "raspbian" ] || [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ]; then
        if command -v raspi-config &>/dev/null; then
            if [ -z "$DRY_RUN" ]; then
                # raspi-config overlay method
                raspi-config nonint do_overlayfs 0 2>/dev/null || warn "raspi-config overlay failed — enable manually"
                info "Read-only root enabled (overlayfs)"
            fi
        else
            # Manual overlayfs via cmdline.txt
            local cmdline="/boot/firmware/cmdline.txt"
            [ -f "$cmdline" ] || cmdline="/boot/cmdline.txt"
            if [ -f "$cmdline" ]; then
                dry_run_hint "Append 'fastboot ro' to $cmdline"
                if [ -z "$DRY_RUN" ]; then
                    if ! grep -q 'fastboot' "$cmdline"; then
                        sed -i 's/$/ fastboot ro/' "$cmdline"
                        info "Read-only root enabled via $cmdline"
                    else
                        info "Read-only root already configured"
                    fi
                fi
            fi
        fi
    elif [ "$OS_ID" = "fedora" ]; then
        warn "Fedora: enable read-only root manually via 'systemd-readahead' or overlayfs"
    fi
}
print_summary() {
    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "sinksonic")
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "  SinkSonic setup complete!"
    echo "══════════════════════════════════════════════════"
    echo ""
    echo "  Web UI:   http://${hostname}.local:8080"
    echo "  Config:   $DATA_DIR/sinksonic.yaml"
    echo "  User:     $SINKSONIC_USER"
    echo ""
    echo "  Desktop setup:"
    echo "    pactl load-module module-tunnel-sink \\"
    echo "      server=tcp:${hostname}.local:4713 \\"
    echo "      sink_name=sinksonic"
    echo ""
    echo "  Then select 'SinkSonic' in your sound settings."
    echo ""
}

# ── Dry-run helper ─────────────────────────────────────────────────────────────
dry_run_hint() {
    if [ -n "$DRY_RUN" ]; then
        echo "  [DRY RUN] $1"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo "══════════════════════════════════════════════════"
    echo "  SinkSonic — one-liner setup"
    echo "══════════════════════════════════════════════════"
    echo ""

    if [ "$(id -u)" -ne 0 ] && [ -z "$DRY_RUN" ]; then
        err "This script must be run as root (or with --dry-run)"
        exit 1
    fi

    if [ -n "$DRY_RUN" ]; then
        echo ""
        info "DRY RUN mode — no changes will be made"
        echo ""
    fi

    detect_os
    install_packages
    enable_services
    configure_pipewire_tcp
    enable_readonly_root
    create_user
    setup_data_dir
    deploy_docker
    print_summary
}

main "$@"
