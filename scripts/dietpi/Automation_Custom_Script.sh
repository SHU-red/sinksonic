#!/bin/bash
# SinkSonic — DietPi first-boot setup
# Runs automatically via AUTO_SETUP_CUSTOM_SCRIPT_EXEC in dietpi.txt.
set -euo pipefail

LOG="/var/log/sinksonic-firstboot.log"
exec > "$LOG" 2>&1

echo "[SinkSonic] Setup starting at $(date)"
PIPEWIRE_USER="${PIPEWIRE_USER:-dietpi}"
PIPEWIRE_UID=$(id -u "$PIPEWIRE_USER")

# ── 1. PipeWire TCP listener ──────────────────────────────────────────────────
echo "[SinkSonic] Configuring PipeWire TCP..."
mkdir -p /etc/pipewire/pipewire-pulse.conf.d
cat > /etc/pipewire/pipewire-pulse.conf.d/10-network-tcp.conf << 'CONF'
pulse.cmd = [{ cmd = "load-module" args = "module-native-protocol-tcp auth-anonymous=true" flags = [ nofail ] }]
pulse.properties = { pulse.idle.timeout = 0 }
stream.properties = { resample.quality = 14 }
CONF

# ── 2. Prepare user and start PipeWire ────────────────────────────────────────
echo "[SinkSonic] Starting PipeWire as $PIPEWIRE_USER (UID $PIPEWIRE_UID)..."
usermod -aG audio,video "$PIPEWIRE_USER" 2>/dev/null || true
loginctl enable-linger "$PIPEWIRE_USER" 2>/dev/null || true

# Create runtime directory and start PipeWire services
mkdir -p "/run/user/$PIPEWIRE_UID"
chown "$PIPEWIRE_USER:$PIPEWIRE_USER" "/run/user/$PIPEWIRE_UID"
chmod 700 "/run/user/$PIPEWIRE_UID"

run_as_user() {
    sudo -u "$PIPEWIRE_USER" XDG_RUNTIME_DIR="/run/user/$PIPEWIRE_UID" "$@"
}

run_as_user pipewire &>/dev/null &
sleep 2
run_as_user wireplumber &>/dev/null &
sleep 2
run_as_user pipewire-pulse &>/dev/null &
sleep 2

echo "[SinkSonic] PipeWire sockets: $(ls /run/user/$PIPEWIRE_UID/pipewire-0 2>/dev/null || echo 'MISSING')"

# ── 3. Move Docker to writable partition ──────────────────────────────────────
echo "[SinkSonic] Moving Docker data to /mnt/dietpi_userdata/docker..."
mkdir -p /mnt/dietpi_userdata/docker /etc/docker
cat > /etc/docker/daemon.json << 'CONF'
{ "data-root": "/mnt/dietpi_userdata/docker", "storage-driver": "overlay2", "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
CONF
systemctl restart docker 2>/dev/null || true

# ── 4. Pull and start SinkSonic container ─────────────────────────────────────
echo "[SinkSonic] Starting SinkSonic container..."
mkdir -p /mnt/dietpi_userdata/sinksonic
cd /mnt/dietpi_userdata/sinksonic

# Download compose file
curl -sSL -o docker-compose.yml \
    https://raw.githubusercontent.com/SHU-red/sinksonic/main/docker-compose.yml

# Create override with correct UID for this system
cat > docker-compose.override.yml << OVERRIDE
services:
  sinksonic:
    environment:
      - XDG_RUNTIME_DIR=/run/user/$PIPEWIRE_UID
    volumes:
      - sinksonic_data:/data
      - /run/user/$PIPEWIRE_UID:/run/user/$PIPEWIRE_UID:ro
      - /run/systemd:/run/systemd:rw
OVERRIDE

# Pull and start
docker compose pull 2>&1 || echo "[SinkSonic] WARNING: pull failed"
docker compose up -d 2>&1 || echo "[SinkSonic] WARNING: start failed"

# ── 5. Enable read-only overlayfs ─────────────────────────────────────────────
echo "[SinkSonic] Enabling read-only overlayfs..."
if [ -f /DietPi/dietpi/dietpi-overlay ]; then
    /DietPi/dietpi/dietpi-overlay 1 2>/dev/null || true
elif command -v dietpi-config &>/dev/null; then
    echo "[SinkSonic] Enable overlay manually: dietpi-config → Advanced → Overlay"
else
    echo "[SinkSonic] Overlay not available — SD card writes not protected"
fi

echo "[SinkSonic] Setup done at $(date)"
echo "[SinkSonic] Web UI: http://SinkSonic.local:8080"
