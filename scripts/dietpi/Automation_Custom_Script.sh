#!/bin/bash
# SinkSonic — DietPi post-install (last mile)
# Runs automatically during first-boot setup, triggered by
# AUTO_SETUP_CUSTOM_SCRIPT_EXEC in dietpi.txt.
#
# DietPi execution order:
#   1. Install software (Docker via ID 134)
#   2. Install APT packages (PipeWire etc.)
#   3. Run THIS script (post-install)
#   4. Reboot

set -euo pipefail
LOG="/var/log/sinksonic-firstboot.log"
exec > "$LOG" 2>&1

echo "[SinkSonic] Post-install starting at $(date)"

# ── 1. PipeWire TCP config ────────────────────────────────────────────────────
echo "[SinkSonic] Configuring PipeWire TCP..."
mkdir -p /etc/pipewire/pipewire-pulse.conf.d
cat > /etc/pipewire/pipewire-pulse.conf.d/10-network-tcp.conf << 'CONF'
pulse.cmd = [
    { cmd = "load-module"
      args = "module-native-protocol-tcp auth-anonymous=true"
      flags = [ nofail ] }
]
pulse.properties = { pulse.idle.timeout = 0 }
stream.properties = { resample.quality = 14 }
CONF
systemctl restart pipewire-pulse 2>/dev/null || true

# ── 2. Move Docker data to writable partition ─────────────────────────────────
echo "[SinkSonic] Moving Docker data to /mnt/dietpi_userdata/docker..."
mkdir -p /mnt/dietpi_userdata/docker
if [ -d /var/lib/docker ] && [ "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
    cp -a /var/lib/docker/* /mnt/dietpi_userdata/docker/ 2>/dev/null || true
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'CONF'
{ "data-root": "/mnt/dietpi_userdata/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" } }
CONF
systemctl restart docker 2>/dev/null || true

# ── 3. SinkSonic data dir ─────────────────────────────────────────────────────
mkdir -p /mnt/dietpi_userdata/sinksonic
if ! id sinksonic &>/dev/null; then
    useradd -m -G audio,video sinksonic
fi
chown sinksonic:sinksonic /mnt/dietpi_userdata/sinksonic

# ── 4. Start SinkSonic container ──────────────────────────────────────────────
echo "[SinkSonic] Starting SinkSonic container..."
curl -sSL -o /mnt/dietpi_userdata/sinksonic/docker-compose.yml \
    https://raw.githubusercontent.com/SHU-red/sinksonic/main/docker-compose.yml
cd /mnt/dietpi_userdata/sinksonic
docker compose up -d 2>&1 || echo "[SinkSonic] WARNING: docker compose failed"

# ── 5. Enable read-only root (overlayfs) ──────────────────────────────────────
echo "[SinkSonic] Enabling overlayfs..."
/DietPi/dietpi/dietpi-overlay 1 2>/dev/null || \
    echo "[SinkSonic] WARNING: overlay enable failed, enable manually: dietpi-config → Advanced → Overlay"

echo "[SinkSonic] Done at $(date)"
echo "[SinkSonic] Web UI: http://SinkSonic.local:8080"
