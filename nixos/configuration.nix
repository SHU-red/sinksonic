{ config, lib, pkgs, webui, ... }:

{
  ##############################################################################
  # System basics
  ##############################################################################
  networking = {
    hostName = "sinksonic";
    useDHCP = true;
    # No static wireless config — WiFi is set up dynamically at boot
    # by the wifi-connect service if configured in /data/sinksonic.yaml.
    wireless.enable = false;
  };

  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "C.UTF-8";

  # Allow firmware packages for WiFi/BT on Pi 3
  hardware.enableRedistributableFirmware = true;

  ##############################################################################
  # Boot — Pi 3B kernel/firmware from nixos-hardware module
  ##############################################################################
  boot = {
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    kernelModules = [
      "bcm2835_codec"
      "smsc95xx"      # USB Ethernet (LAN9512 on Pi 3B)
    ];
  };

  ##############################################################################
  # PipeWire — network audio mixing (built-in ZeroConf discovery)
  ##############################################################################
  services = {
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;       # PulseAudio compat for network clients
      wireplumber.enable = true; # Session management (auto routing)

      # PulseAudio TCP network listener — allows desktop hosts to stream audio.
      # Uses pulse.cmd with TCP load-module FIRST and nofail flags on all
      # entries. Must be first because module-always-sink errors "File exists"
      # and without nofail, processing stops before reaching TCP.
      # context.exec doesn't work here: it runs before the pulse socket is
      # ready, so pactl can't connect (chicken-and-egg).
      configPackages = [
        (pkgs.writeTextDir "share/pipewire/pipewire-pulse.conf.d/10-network-tcp.conf" ''
          pulse.cmd = [
              {   cmd = "load-module"
                  args = "module-native-protocol-tcp auth-anonymous=1"
                  flags = [ nofail ]
              }
              {   cmd = "load-module"
                  args = "module-always-sink"
                  condition = [ { pulse.cmd.always-sink = !false } ]
                  flags = [ nofail ]
              }
              {   cmd = "load-module"
                  args = "module-device-manager"
                  condition = [ { pulse.cmd.device-manager = !false } ]
                  flags = [ nofail ]
              }
              {   cmd = "load-module"
                  args = "module-device-restore"
                  condition = [ { pulse.cmd.device-restore = !false } ]
                  flags = [ nofail ]
              }
              {   cmd = "load-module"
                  args = "module-stream-restore"
                  condition = [ { pulse.cmd.stream-restore = !false } ]
                  flags = [ nofail ]
              }
          ]
          pulse.properties = {
              pulse.idle.timeout = 0
          }
          # Medium quality resampling (SRC_SINC_MEDIUM_QUALITY).
          # Quality 14 (SRC_SINC_BEST_QUALITY) is too CPU-intensive
          # for Pi 3B's Cortex-A53 and causes stuttering on network streams.
          stream.properties = {
              resample.quality = 7
          }
        '')
      ];
    };
    # ZeroConf/mDNS for .local discovery
    avahi = {
      enable = true;
      nssmdns4 = true;
    };

    # SSH for management
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = true;
        PubkeyAuthentication = true;
      };
    };
  };

  ##############################################################################
  # PipeWire services — run permanently (disable socket activation)
  # Socket activation stops all daemons when idle, which kills the TCP
  # listener (port 4713) and makes the Pi undetectable as an audio sink.
  # The original service units have Requires=pipewire.socket which blocks
  # startup when the socket is masked — override to remove that dependency.
  ##############################################################################
  systemd.user.services.pipewire = {
    unitConfig = {
      X-OnlyByActivation = lib.mkForce false;
      # Remove Requires=pipewire.socket (keeps dbus.service)
      Requires = lib.mkForce [ "dbus.service" ];
    };
    wantedBy = [ "default.target" ];
  };
  systemd.user.services.wireplumber = {
    unitConfig.X-OnlyByActivation = lib.mkForce false;
    wantedBy = [ "default.target" ];
    requires = [ "pipewire.service" ];
  };
  systemd.user.services.pipewire-pulse = {
    unitConfig = {
      X-OnlyByActivation = lib.mkForce false;
      # Remove Requires=pipewire-pulse.socket — we start directly
      Requires = lib.mkForce [ ];
    };
    wantedBy = [ "default.target" ];
    requires = [ "pipewire.service" ];
    serviceConfig = {
      KillMode = lib.mkForce "mixed";
      TimeoutStopSec = lib.mkForce 0;
    };
  };

  # Apply audio settings from /data/sinksonic.yaml at boot
  # Uses dynamic sink discovery instead of hardcoded names
  systemd.user.services.apply-audio-config = {
    description = "Apply audio settings from config";
    after = [ "wireplumber.service" "pipewire-pulse.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      ExecStart = [
        "${pkgs.bash}/bin/bash -c 'SINK=$(${pkgs.pulseaudio}/bin/pactl list sinks short | head -1 | awk \"{print \\$2}\"); [ -n \"$SINK\" ] && ${pkgs.pulseaudio}/bin/pactl set-sink-volume \"$SINK\" 100% && ${pkgs.pulseaudio}/bin/pactl set-sink-mute \"$SINK\" 0 || true'"
        "${pkgs.bash}/bin/bash -c 'QV=$(grep buffer_size /data/sinksonic.yaml 2>/dev/null | head -1 | sed \"s/.*buffer_size: *//\"); [ -n \"$QV\" ] && ${pkgs.pipewire}/bin/pw-metadata -n settings 0 clock.force-quantum \"$QV\" 2>/dev/null || true'"
      ];
    };
  };

  ##############################################################################
  # Web UI — Go binary for monitoring/controlling
  ##############################################################################
  systemd.services."sinksonic-webui" = {
    description = "SinkSonic Web UI";
    after = [ "network.target" "user@1000.service" ];
    # Add pw-cli, pactl, wpctl to PATH for API handlers.
    # sudo is at /run/wrappers/bin/sudo on NixOS (setuid wrapper),
    # NOT in pkgs.sudo's nix store path.
    path = with pkgs; [ pipewire pulseaudio wireplumber ];
    serviceConfig = {
      Type = "simple";
      User = "sinksonic";
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      ExecStart = "${webui}/bin/sinksonic-webui";
      Restart = "on-failure";
      RestartSec = 5;
      Environment = [
        "LISTEN_ADDR=0.0.0.0"
        "LISTEN_PORT=80"
        "CONFIG_PATH=/data/sinksonic.yaml"
        "XDG_RUNTIME_DIR=/run/user/1000"
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
      ];
    };
    wantedBy = [ "multi-user.target" ];
  };

  # Open port 80 for web UI, 4713 for PulseAudio network
  networking.firewall.allowedTCPPorts = [ 80 4713 ];

  # Real-time scheduling for PipeWire
  security.rtkit.enable = true;

  ##############################################################################
  # Users
  ##############################################################################
  users.users = {
    sinksonic = {
      isNormalUser = true;
      extraGroups = [ "audio" "video" "pipewire" "wheel" "systemd-journal" ];
      initialPassword = "changeme";
      home = "/home/sinksonic";
      createHome = true;
      linger = true;  # Keep user session alive forever — without this,
                      # user@1000.service dies shortly after boot which
                      # kills ALL user services (pipewire, wireplumber,
                      # pipewire-pulse). They restart but the cycle
                      # causes intermittent failures.
    };
  };
  users.users.root.initialPassword = "changeme";

  # RT limits for audio group
  security.pam.loginLimits = [
    { domain = "@audio";   item = "rtprio";  type = "-"; value = 95; }
    { domain = "@audio";   item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "@pipewire"; item = "rtprio";  type = "-"; value = 95; }
    { domain = "@pipewire"; item = "memlock"; type = "-"; value = "unlimited"; }
  ];

  # Allow sinksonic user to reboot from web UI without password
  security.sudo.extraRules = [
    { users = [ "sinksonic" ];
      commands = [
        { command = "/run/current-system/sw/bin/reboot";   options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/poweroff"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  ##############################################################################
  # Packages
  ##############################################################################
  environment.systemPackages = with pkgs; [
    pipewire
    wireplumber
    alsa-utils
    pulseaudio
    iproute2
    curl
    jq
    vim
    wpa_supplicant  # for wpa_cli / wpa_passphrase debugging
  ];

  ##############################################################################
  # Read-only root filesystem — protect SD card from wear
  # Writable directories mounted as tmpfs (RAM).
  # /nix/store is mounted read-only by default via boot.nixStoreMountOpts.
  ##############################################################################
  fileSystems."/var"  = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=128M" "mode=0755" ]; };
  fileSystems."/tmp"  = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=64M" "mode=1777" ]; };
  fileSystems."/home" = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=64M" "mode=0755" ]; };
  fileSystems."/root" = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=32M" "mode=0700" ]; };
  fileSystems."/etc"  = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=32M" "mode=0755" ]; };

  ##############################################################################
  # Persistent data — small ext4 partition, written only on config changes
  ##############################################################################
  fileSystems."/data" = {
    device = "/dev/disk/by-label/SINKSONIC_DATA";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  ##############################################################################
  # Boot-time setup
  ##############################################################################

  # Ensure /home/sinksonic exists at every boot (tmpfs wipes it)
  systemd.tmpfiles.rules = [
    "d /home/sinksonic 0755 sinksonic users - -"
  ];

  # First boot: copy the shipped default config to persistent /data
  systemd.services."init-sinksonic-config" = {
    description = "Initialize persistent config on first boot";
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    before = [ "generate-wifi-config.service" ];
    wantedBy = [ "generate-wifi-config.service" ];
    unitConfig.ConditionPathExists = "!/data/sinksonic.yaml";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      cp /etc/sinksonic/config.yaml /data/sinksonic.yaml
      echo "Default config copied to /data/sinksonic.yaml"
    '';
  };

  # Ensure /data is writable by the sinksonic user (used by web UI)
  systemd.services."fix-data-perms" = {
    description = "Fix /data permissions for sinksonic user";
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    before = [ "sinksonic-webui.service" ];
    wantedBy = [ "sinksonic-webui.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      chown -R sinksonic:users /data
      echo "Permissions set on /data"
    '';
  };

  # Generate wpa_supplicant.conf from sinksonic.yaml
  systemd.services."generate-wifi-config" = {
    description = "Generate wpa_supplicant config from /data/sinksonic.yaml";
    after = [ "data.mount" "init-sinksonic-config.service" ];
    requires = [ "data.mount" ];
    before = [ "wifi-connect.service" ];
    wantedBy = [ "wifi-connect.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -f /data/sinksonic.yaml ]; then
        echo "No SinkSonic config found"
        exit 0
      fi

      SSID=$(grep 'ssid:' /data/sinksonic.yaml 2>/dev/null | head -1 | sed 's/.*ssid: *"\\(.*\\)"/\1/')

      if [ -z "$SSID" ]; then
        echo "No WiFi SSID configured in sinksonic.yaml"
        rm -f /data/wpa_supplicant.conf
        exit 0
      fi

      PASS=$(grep 'password:' /data/sinksonic.yaml 2>/dev/null | head -1 | sed 's/.*password: *"\\(.*\\)"/\1/')

      cat > /data/wpa_supplicant.conf << WEOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1
country=DE

network={
  ssid="$SSID"
WEOF
      if [ -n "$PASS" ]; then
        echo "  psk=\"$PASS\"" >> /data/wpa_supplicant.conf
      else
        echo "  key_mgmt=NONE" >> /data/wpa_supplicant.conf
      fi
      echo "}"
      echo "WiFi config generated for SSID: $SSID"
    '';
  };

  # Connect to WiFi using wpa_supplicant. DHCP for wlan0 is handled by the
  # system-wide dhcpcd (networking.useDHCP = true), which learns about new
  # interfaces automatically when wpa_supplicant brings wlan0 up.
  # Only runs if generate-wifi-config created a config file.
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

  ##############################################################################
  # SD image
  ##############################################################################
  environment.etc."sinksonic/config.yaml".source = ../config/sinksonic.yaml;

  sdImage = {
    rootFilesystemCreator = ./make-ext4-fs.nix;
    compressImage = false;
    postBuildCommands = ''
      echo "=== Adding data partition ==="

      root_end=$(sfdisk -l "$img" 2>/dev/null | grep -E 'img2|\.img2' | awk '{print $4}')
      if [ -z "$root_end" ]; then
        root_end=$(sfdisk -l "$img" 2>/dev/null | tail -1 | awk '{print $4}')
      fi
      if [ -z "$root_end" ]; then
        echo "ERROR: Could not get root partition end"
        exit 1
      fi

      data_sectors=$((64 * 1024 * 2))
      data_start=$(( ((root_end + 1 + 2047) / 2048) * 2048 ))
      new_size=$(( (data_start + data_sectors + 1024) * 512 ))

      truncate -s $new_size "$img"
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
