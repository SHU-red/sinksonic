# SinkSonic

Declarative network audio sink for Raspberry Pi 3B. Stream audio from any desktop to the Pi's 3.5mm analog output via PipeWire over TCP. One Nix flake — flash once, done.

## Architecture

```
Desktop                                Pi 3B (NixOS)
────────                                ─────────────

  Any audio app ──► module-null-sink ──► TCP:4713 ──► pipewire-pulse ──► wireplumber ──► 3.5mm jack
                    "SinkSonic"
                    (visible in Sound Settings)
```

## Build

Requires Nix with flake support and QEMU for aarch64 emulation.

```bash
# Fedora (one-time)
sudo dnf install -y qemu-user-static

cd /home/shured/GitHub/sinksonic
nix build --print-build-logs    # ~1-3h
```

Output: `result/sd-image/nixos-image-sd-card-*-aarch64-linux.img`

## Flash

```bash
sudo dd if=result/sd-image/nixos-image-sd-card-*-aarch64-linux.img of=/dev/sda bs=1M oflag=direct,dsync status=progress
```

## First boot

1. Insert SD card, connect Ethernet, power on
2. Find it: `ssh sinksonic@sinksonic.local` (password: `changeme`)
3. Web UI: `http://sinksonic.local`

PipeWire services run permanently (socket activation disabled).

## Desktop setup (one time)

Create a null sink that forwards audio to the Pi over TCP:

```bash
cat > ~/.local/bin/sinksonic-sink.sh << 'EOF'
#!/bin/bash
# SinkSonic network tunnel — forwards local audio to the Pi
exec pactl load-module module-tunnel-sink server=tcp:sinksonic.local:4713 sink_name=sinksonic
EOF
chmod +x ~/.local/bin/sinksonic-sink.sh
```

Then run it, and select **"SinkSonic"** in your sound settings.

## Troubleshooting

### Pi side

```bash
ssh sinksonic@sinksonic.local "systemctl --user is-active pipewire wireplumber pipewire-pulse"
ssh sinksonic@sinksonic.local "ss -tlnp | grep 4713"
curl http://sinksonic.local/api/status
```

### Desktop side

```bash
pactl list sinks short | grep sinksonic
PULSE_SINK=sinksonic speaker-test -c 2 -l 1 -t sine
```

## Filesystem layout

```
SD Card (read-only):
  /boot/firmware   ── kernel, firmware, device tree
  /                ── ext4 root (remounted ro after boot)
  /nix             ── Nix store (read-only)
  /data            ── ext4 data partition (persistent config)

RAM (tmpfs):
  /var             ── 128MB — logs, state
  /tmp             ── 64MB — scratch
  /home            ── 64MB — user data
  /root            ── 32MB — root home
  /etc             ── 32MB — runtime config
```

## Configuration

All system config lives in `nixos/configuration.nix`. Runtime settings at `config/sinksonic.yaml`.

To change anything:
1. Edit `nixos/configuration.nix`
2. Rebuild: `nix build --print-build-logs`
3. Flash new image

## License

MIT
