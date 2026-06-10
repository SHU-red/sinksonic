#!/bin/bash
# SinkSonic — DietPi first-boot setup
# Runs automatically from /boot/Automation_Custom_Script.sh.
# Installs everything and creates systemd services for reboot persistence.
set -euo pipefail

LOG="/var/log/sinksonic-firstboot.log"
exec > "$LOG" 2>&1
echo "[SinkSonic] Setup starting at $(date)"

# ── 1. Wait for network ──────────────────────────────────────────────────────
echo "[SinkSonic] Waiting for network..."
for i in $(seq 1 30); do
    if ping -c 1 -W 2 9.9.9.9 &>/dev/null; then
        echo "[SinkSonic] Network OK"
        break
    fi
    sleep 2
done

# ── 2. Install packages ──────────────────────────────────────────────────────
echo "[SinkSonic] Installing packages..."
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq docker.io docker-cli docker-compose pipewire pipewire-pulse wireplumber pulseaudio-utils avahi-daemon 2>&1 | tail -3

# ── 3. PipeWire TCP config ────────────────────────────────────────────────────
echo "[SinkSonic] Configuring PipeWire TCP..."
mkdir -p /etc/pipewire/pipewire-pulse.conf.d
cat > /etc/pipewire/pipewire-pulse.conf.d/10-network-tcp.conf << 'CONF'
pulse.cmd = [{ cmd = "load-module" args = "module-native-protocol-tcp auth-anonymous=true" flags = [ nofail ] }]
pulse.properties = { pulse.idle.timeout = 0 }
stream.properties = { resample.quality = 14 }
CONF

# ── 4. Start PipeWire as dietpi user ─────────────────────────────────────────
echo "[SinkSonic] Starting PipeWire..."
usermod -aG audio,video dietpi
loginctl enable-linger dietpi 2>/dev/null || true
PW_UID=$(id -u dietpi)
mkdir -p /run/user/$PW_UID
chown dietpi:dietpi /run/user/$PW_UID
chmod 700 /run/user/$PW_UID
su dietpi -c "XDG_RUNTIME_DIR=/run/user/$PW_UID pipewire &>/dev/null &"
sleep 2
su dietpi -c "XDG_RUNTIME_DIR=/run/user/$PW_UID wireplumber &>/dev/null &"
sleep 2
su dietpi -c "XDG_RUNTIME_DIR=/run/user/$PW_UID pipewire-pulse &>/dev/null &"
sleep 2

# ── 5. Systemd service: PipeWire ─────────────────────────────────────────────
echo "[SinkSonic] Creating systemd services..."
cat > /etc/systemd/system/sinksonic-pipewire.service << UNIT
[Unit]
Description=SinkSonic PipeWire
After=network.target sound.target
Before=sinksonic-webui.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/mkdir -p /run/user/$PW_UID
ExecStartPre=/bin/chown dietpi:dietpi /run/user/$PW_UID
ExecStartPre=/bin/chmod 700 /run/user/$PW_UID
ExecStart=/bin/su dietpi -c "XDG_RUNTIME_DIR=/run/user/$PW_UID pipewire & wireplumber & pipewire-pulse &"
ExecStop=/bin/pkill -u dietpi pipewire
ExecStop=/bin/pkill -u dietpi wireplumber
ExecStop=/bin/pkill -u dietpi pipewire-pulse
[Install]
WantedBy=multi-user.target
UNIT

# ── 6. Docker data on writable partition ──────────────────────────────────────
echo "[SinkSonic] Configuring Docker..."
mkdir -p /mnt/dietpi_userdata/docker /etc/docker
cat > /etc/docker/daemon.json << 'CONF'
{ "data-root": "/mnt/dietpi_userdata/docker", "storage-driver": "overlay2", "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
CONF
systemctl restart docker

# ── 7. Pull and start SinkSonic container ──────────────────────────────────────
echo "[SinkSonic] Starting SinkSonic container..."
mkdir -p /mnt/dietpi_userdata/sinksonic
cd /mnt/dietpi_userdata/sinksonic
curl -sSL -o docker-compose.yml https://raw.githubusercontent.com/SHU-red/sinksonic/main/docker-compose.yml

cat > docker-compose.override.yml << OVERRIDE
services:
  sinksonic:
    environment:
      - XDG_RUNTIME_DIR=/run/user/$PW_UID
    volumes:
      - sinksonic_data:/data
      - /run/user/$PW_UID:/run/user/$PW_UID:ro
      - /run/systemd:/run/systemd:rw
OVERRIDE

docker compose pull 2>&1
docker compose up -d 2>&1

# ── 8. Systemd service: SinkSonic container ───────────────────────────────────
cat > /etc/systemd/system/sinksonic-webui.service << UNIT
[Unit]
Description=SinkSonic Web UI
After=docker.service sinksonic-pipewire.service
Requires=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/mnt/dietpi_userdata/sinksonic
ExecStartPre=-/usr/bin/docker compose pull
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable sinksonic-pipewire sinksonic-webui
systemctl start sinksonic-webui 2>&1 || true

echo "[SinkSonic] Done at $(date)"
echo "[SinkSonic] Web UI: http://SinkSonic.local"
