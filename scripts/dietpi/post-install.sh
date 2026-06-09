#!/bin/bash
# SinkSonic — DietPi first-boot post-install script
# Runs automatically during DietPi's first-boot setup, BEFORE
# overlayfs is enabled.
#
# Execution order:
#   1. DietPi installs Docker (software ID 134) → real root
#   2. Runs THIS script → real root (persists under overlay)
#   3. DietPi enables overlayfs (AUTO_SETUP_ENABLE_OVERLAYFS=1)
#   4. Reboots into read-only mode
#   5. Docker data lives on excluded partition → stays writable

set -euo pipefail

LOG="/var/log/sinksonic-firstboot.log"
exec > "$LOG" 2>&1

echo "[SinkSonic] DietPi post-install starting at $(date)"

# ── 1. Install PipeWire ────────────────────────────────────────────────────────
echo "[SinkSonic] Installing PipeWire..."
apt-get update -qq
apt-get install -y -qq \
    pipewire \
    pipewire-pulse \
    wireplumber \
    pulseaudio-utils \
    avahi-daemon

# ── 2. Configure PipeWire TCP listener ─────────────────────────────────────────
echo "[SinkSonic] Configuring PipeWire TCP..."
mkdir -p /etc/pipewire/pipewire-pulse.conf.d
cat > /etc/pipewire/pipewire-pulse.conf.d/10-network-tcp.conf << 'CONF'
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

# ── 3. Enable system-wide services ─────────────────────────────────────────────
echo "[SinkSonic] Enabling services..."
systemctl enable --now pipewire-pulse 2>/dev/null || true
systemctl enable --now wireplumber 2>/dev/null || true
systemctl enable --now avahi-daemon 2>/dev/null || true

# ── 4. Move Docker data to writable partition ──────────────────────────────────
# After overlayfs is enabled, /var/lib/docker would be read-only.
# Move it to the DietPi userdata partition (excluded from overlay).
echo "[SinkSonic] Moving Docker data to writable partition..."
DOCKER_DATA="/mnt/dietpi_userdata/docker"
if [ ! -d "$DOCKER_DATA" ]; then
    mkdir -p "$DOCKER_DATA"
    # Copy existing Docker data (if any)
    if [ -d /var/lib/docker ] && [ "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
        cp -a /var/lib/docker/* "$DOCKER_DATA/" 2>/dev/null || true
    fi
fi

# Configure Docker to use the new data root
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'CONF'
{
    "data-root": "/mnt/dietpi_userdata/docker",
    "storage-driver": "overlay2",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
CONF
systemctl restart docker 2>/dev/null || true

# ── 5. Create sinksonic user with linger ───────────────────────────────────────
echo "[SinkSonic] Creating sinksonic user..."
if ! id sinksonic &>/dev/null; then
    useradd -m -G audio,video sinksonic
fi
loginctl enable-linger sinksonic 2>/dev/null || true

# ── 6. Enable PipeWire user services ──────────────────────────────────────────
echo "[SinkSonic] Enabling PipeWire user services..."
SINKSONIC_UID=$(id -u sinksonic)
for svc in pipewire pipewire-pulse wireplumber; do
    if [ -f "/usr/lib/systemd/user/$svc.service" ]; then
        sudo -u sinksonic XDG_RUNTIME_DIR="/run/user/$SINKSONIC_UID" \
            systemctl --user enable "$svc" 2>/dev/null || true
    fi
done

# ── 7. Create data directory ──────────────────────────────────────────────────
echo "[SinkSonic] Setting up data directory..."
DATA_DIR="/mnt/dietpi_userdata/sinksonic"
mkdir -p "$DATA_DIR"
chown sinksonic:sinksonic "$DATA_DIR"

# ── 8. Start SinkSonic container ──────────────────────────────────────────────
echo "[SinkSonic] Starting SinkSonic container..."

# Download docker-compose.yml (need explicit path, not in a dir yet)
curl -sSL -o "$DATA_DIR/docker-compose.yml" \
    https://raw.githubusercontent.com/SHU-red/sinksonic/main/docker-compose.yml

cd "$DATA_DIR"
docker compose up -d 2>&1 || echo "[SinkSonic] WARNING: docker compose failed"

echo "[SinkSonic] Setup complete at $(date)"
echo "[SinkSonic] Web UI: http://sinksonic.local:8080"
