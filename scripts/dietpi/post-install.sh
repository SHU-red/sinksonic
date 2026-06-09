#!/bin/bash
# SinkSonic — DietPi first-boot post-install script
# Runs automatically after DietPi's first-boot setup completes.
# Installs PipeWire, configures TCP, starts the SinkSonic container.
#
# This is called by AUTO_SETUP_CUSTOM_SCRIPT_EXEC in dietpi.txt.

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

# ── 3. Enable services ────────────────────────────────────────────────────────
echo "[SinkSonic] Enabling services..."
systemctl enable --now pipewire-pulse 2>/dev/null || true
systemctl enable --now wireplumber 2>/dev/null || true
systemctl enable --now avahi-daemon 2>/dev/null || true

# ── 4. Create sinksonic user with linger ───────────────────────────────────────
echo "[SinkSonic] Creating sinksonic user..."
if ! id sinksonic &>/dev/null; then
    useradd -m -G audio,video sinksonic
fi
loginctl enable-linger sinksonic 2>/dev/null || true

# ── 5. Enable PipeWire user services ──────────────────────────────────────────
echo "[SinkSonic] Enabling PipeWire user services..."
SINKSONIC_UID=$(id -u sinksonic)
for svc in pipewire pipewire-pulse wireplumber; do
    if [ -f "/usr/lib/systemd/user/$svc.service" ]; then
        sudo -u sinksonic XDG_RUNTIME_DIR="/run/user/$SINKSONIC_UID" \
            systemctl --user enable "$svc" 2>/dev/null || true
    fi
done

# ── 6. Create data directory ──────────────────────────────────────────────────
echo "[SinkSonic] Setting up data directory..."
DATA_DIR="/mnt/dietpi_userdata/sinksonic"
mkdir -p "$DATA_DIR"
chown sinksonic:sinksonic "$DATA_DIR"

# ── 7. Start SinkSonic container ──────────────────────────────────────────────
echo "[SinkSonic] Starting SinkSonic container..."
mkdir -p "$DATA_DIR"

# Download docker-compose.yml
curl -sSL -o "$DATA_DIR/docker-compose.yml" \
    https://raw.githubusercontent.com/SHU-red/sinksonic/main/docker-compose.yml

# Start the container
cd "$DATA_DIR"
docker compose up -d 2>&1 || echo "[SinkSonic] WARNING: docker compose failed"

echo "[SinkSonic] Setup complete at $(date)"
echo "[SinkSonic] Web UI: http://sinksonic.local:8080"
