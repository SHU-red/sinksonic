# SinkSonic — Raspberry Pi 3B image configuration
#
# Single file combining the generic module with Pi 3B hardware config
# and sd-image builder for a flash-and-forget experience.
#
# Import this (via the flake) on a build host:
#   nix build github:SHU-red/sinksonic#sd-image
#   sudo dd if=result of=/dev/sda bs=1M oflag=direct,dsync status=progress

{ config, lib, pkgs, webui, nixos-hardware, nixpkgs, ... }:

{
  imports = [
    ./module.nix
    nixos-hardware.nixosModules.raspberry-pi-3
    "${nixpkgs.outPath}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
  ];

  # Enable the module with the web UI binary
  services.sinksonic = {
    enable = true;
    webui.package = webui;
  };

  # ── Pi 3B hardware ──────────────────────────────────────────────────────

  boot = {
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    kernelModules = [
      "bcm2835_codec"          # Video codec (VCHIQ)
      "smsc95xx"               # USB Ethernet (LAN9512)
      "snd-bcm2835"            # 3.5mm analog audio output
      "snd-soc-hdmi-codec"     # HDMI digital audio
    ];
  };

  hardware.raspberry-pi.configtxt.settings.all.dtparam = [ "audio=on" ];
  hardware.enableRedistributableFirmware = true;

  # ── Networking ───────────────────────────────────────────────────────────

  networking = {
    hostName = "sinksonic";
    useDHCP = true;
    wireless.enable = false;  # WiFi handled by separate service
  };

  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "C.UTF-8";

  # ── Read-only root (tmpfs) — protects SD card from wear ────────────────

  fileSystems."/var"  = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=128M" "mode=0755" ]; };
  fileSystems."/tmp"  = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=64M" "mode=1777" ]; };
  fileSystems."/home" = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=64M" "mode=0755" ]; };
  fileSystems."/root" = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=32M" "mode=0700" ]; };
  fileSystems."/etc"  = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=32M" "mode=0755" ]; };

  # Persistent data partition (small ext4, only written on config changes)
  fileSystems."/data" = {
    device = "/dev/disk/by-label/SINKSONIC_DATA";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  # ── Boot services ────────────────────────────────────────────────────────

  # Recreate /home on every boot (tmpfs wipes it)
  systemd.tmpfiles.rules = [
    "d /home/sinksonic 0755 sinksonic users - -"
  ];

  # First boot: copy default config to persistent /data
  systemd.services."init-sinksonic-config" = {
    description = "Initialize persistent config on first boot";
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    before = [ "generate-wifi-config.service" ];
    wantedBy = [ "generate-wifi-config.service" ];
    unitConfig.ConditionPathExists = "!/data/sinksonic.yaml";
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      cp /etc/sinksonic/config.yaml /data/sinksonic.yaml
      chown sinksonic:users /data/sinksonic.yaml
    '';
  };

  # Fix /data ownership for web UI writes
  systemd.services."fix-data-perms" = {
    description = "Fix /data permissions";
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    before = [ "sinksonic-webui.service" ];
    wantedBy = [ "sinksonic-webui.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = "chown -R sinksonic:users /data";
  };

  # Generate wpa_supplicant.conf from yaml config
  systemd.services."generate-wifi-config" = {
    description = "Generate wpa_supplicant config from /data/sinksonic.yaml";
    after = [ "data.mount" "init-sinksonic-config.service" ];
    requires = [ "data.mount" ];
    before = [ "wifi-connect.service" ];
    wantedBy = [ "wifi-connect.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      if [ ! -f /data/sinksonic.yaml ]; then exit 0; fi
      SSID=$(grep 'ssid:' /data/sinksonic.yaml 2>/dev/null | head -1 | sed 's/.*ssid: *"\(.*\)"/\1/')
      if [ -z "$SSID" ]; then rm -f /data/wpa_supplicant.conf; exit 0; fi
      PASS=$(grep 'password:' /data/sinksonic.yaml 2>/dev/null | head -1 | sed 's/.*password: *"\(.*\)"/\1/')
      cat > /data/wpa_supplicant.conf << WEOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1
country=DE
network={
  ssid="$SSID"
WEOF
      [ -n "$PASS" ] && echo "  psk=\"$PASS\"" >> /data/wpa_supplicant.conf || echo "  key_mgmt=NONE" >> /data/wpa_supplicant.conf
      echo "}"
      echo "WiFi config generated for SSID: $SSID"
    '';
  };

  # Connect to WiFi
  systemd.services."wifi-connect" = {
    description = "WiFi connection via wpa_supplicant";
    after = [ "data.mount" "generate-wifi-config.service" "sys-subsystem-net-devices-wlan0.device" ];
    requires = [ "data.mount" ];
    wants = [ "network.target" ];
    unitConfig.ConditionPathExists = "/data/wpa_supplicant.conf";
    serviceConfig = {
      Type = "simple";
      ExecStartPre = "${pkgs.iproute2}/bin/ip link set wlan0 up";
      ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -i wlan0 -c /data/wpa_supplicant.conf";
      Restart = "on-failure";
      RestartSec = 10;
    };
    wantedBy = [ "multi-user.target" ];
  };

  # ── Shipped default config ──────────────────────────────────────────────
  environment.etc."sinksonic/config.yaml".source = ../config/sinksonic.yaml;

  # ── sd-image layout ─────────────────────────────────────────────────────

  sdImage = {
    rootFilesystemCreator = ./make-ext4-fs.nix;
    compressImage = false;
    postBuildCommands = ''
      echo "=== Adding data partition ==="
      root_end=$(sfdisk -l "$img" 2>/dev/null | grep -E 'img2|\.img2' | awk '{print $4}')
      if [ -z "$root_end" ]; then
        root_end=$(sfdisk -l "$img" 2>/dev/null | tail -1 | awk '{print $4}')
      fi
      [ -z "$root_end" ] && { echo "ERROR: no root partition end"; exit 1; }
      data_sectors=$((64 * 1024 * 2))
      data_start=$(( ((root_end + 1 + 2047) / 2048) * 2048 ))
      truncate -s $(( (data_start + data_sectors + 1024) * 512 )) "$img"
      echo ",$data_sectors,83" | sfdisk -a "$img" --no-reread --no-tell-kernel 2>&1 || true
      dd if="$img" of=/tmp/data_part.img bs=512 skip=$data_start count=$data_sectors 2>/dev/null
      mkfs.ext4 -F -L SINKSONIC_DATA /tmp/data_part.img 2>&1
      dd if=/tmp/data_part.img of="$img" bs=512 seek=$data_start count=$data_sectors conv=notrunc 2>/dev/null
      rm -f /tmp/data_part.img
      echo "=== Data partition done ==="
    '';
  };

  system.stateVersion = "24.05";
}
