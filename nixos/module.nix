{ config, lib, pkgs, ... }:

let
  cfg = config.services.sinksonic;
  sinksonicUser = cfg.user;
in

with lib;

{
  ##############################################################################
  # Options
  ##############################################################################
  options.services.sinksonic = {
    enable = mkEnableOption "SinkSonic network audio receiver";

    user = mkOption {
      type = types.str;
      default = "sinksonic";
      description = "Dedicated system user for PipeWire and Web UI.";
    };

    tcpPort = mkOption {
      type = types.port;
      default = 4713;
      description = "PulseAudio TCP listener port for incoming audio streams.";
    };

    authAnonymous = mkOption {
      type = types.bool;
      default = true;
      description = "Allow PulseAudio TCP connections without authentication.";
    };

    resampleQuality = mkOption {
      type = types.ints.between 1 14;
      default = 7;
      description = ''
        PipeWire resample quality (1-14). 7 = SRC_SINC_MEDIUM_QUALITY.
        14 = SRC_SINC_BEST_QUALITY. Higher = better quality but more CPU.
        Only matters when source and sink sample rates differ.
      '';
    };

    bufferSize = mkOption {
      type = types.int;
      default = 2048;
      description = "Default PipeWire clock quantum in frames. 2048 = ~43ms at 48kHz.";
    };

    minBufferSize = mkOption {
      type = types.int;
      default = 1024;
      description = "Minimum PipeWire clock quantum.";
    };

    maxBufferSize = mkOption {
      type = types.int;
      default = 8192;
      description = "Maximum PipeWire clock quantum for dynamic scaling.";
    };

    webui = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the SinkSonic web dashboard.";
      };
      port = mkOption {
        type = types.port;
        default = 80;
        description = "Web UI listen port.";
      };
      package = mkOption {
        type = types.package;
        description = "The sinksonic-webui package (Go binary). Must be provided by the flake.";
      };
    };

    firewallOpen = mkOption {
      type = types.bool;
      default = true;
      description = "Open TCP ports in firewall for PulseAudio and Web UI.";
    };

    linger = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Keep the sinksonic user's systemd user session alive permanently.
        Without this, user@.service dies when no one is logged in,
        which kills all PipeWire services and the TCP listener.
      '';
    };

    extraPipewireConfig = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      description = "Extra PipeWire config snippets merged into the daemon config.";
      example = literalExpression ''{ "99-my.conf" = { context.properties.foo = "bar"; }; }'';
    };
  };

  ##############################################################################
  # Config
  ##############################################################################
  config = mkIf cfg.enable {

    # PipeWire as network audio receiver
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      wireplumber.enable = true;

      # Quantum settings for network audio stability
      extraConfig.pipewire = {
        "10-quantum.conf" = {
          context.properties = {
            default.clock.quantum = cfg.bufferSize;
            default.clock.min-quantum = cfg.minBufferSize;
            default.clock.max-quantum = cfg.maxBufferSize;
          };
        };
      } // cfg.extraPipewireConfig;

      # PulseAudio TCP listener — allows desktop hosts to stream audio.
      # pulse.cmd with TCP load-module FIRST and nofail flags on all entries.
      configPackages = [
        (pkgs.writeTextDir "share/pipewire/pipewire-pulse.conf.d/10-network-tcp.conf" ''
          pulse.cmd = [
              {   cmd = "load-module"
                  args = "module-native-protocol-tcp auth-anonymous=${if cfg.authAnonymous then "1" else "0"}"
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
          stream.properties = {
              resample.quality = ${toString cfg.resampleQuality}
          }
        '')
      ];
    };

    # mDNS discovery
    services.avahi = {
      enable = true;
      nssmdns4 = true;
    };

    # SSH for management
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = true;
        PubkeyAuthentication = true;
      };
    };

    # Real-time scheduling for audio
    security.rtkit.enable = true;

    # RT limits for audio group
    security.pam.loginLimits = [
      { domain = "@audio";    item = "rtprio";  type = "-"; value = 95; }
      { domain = "@audio";    item = "memlock"; type = "-"; value = "unlimited"; }
      { domain = "@pipewire"; item = "rtprio";  type = "-"; value = 95; }
      { domain = "@pipewire"; item = "memlock"; type = "-"; value = "unlimited"; }
    ];

    # Open ports in firewall
    networking.firewall.allowedTCPPorts =
      (if cfg.firewallOpen then [ cfg.tcpPort ] else [])
      ++ (if cfg.webui.enable && cfg.firewallOpen then [ cfg.webui.port ] else []);

    ##############################################################################
    # Users
    ##############################################################################
    users.users.${sinksonicUser} = {
      isNormalUser = true;
      extraGroups = [ "audio" "video" "pipewire" "wheel" "systemd-journal" ];
      initialPassword = "changeme";
      home = "/home/${sinksonicUser}";
      createHome = true;
      linger = cfg.linger;
    };
    users.users.root.initialPassword = "changeme";

    # Allow web UI user to reboot/poweroff without password
    security.sudo.extraRules = [
      { users = [ sinksonicUser ];
        commands = [
          { command = "/run/current-system/sw/bin/reboot";   options = [ "NOPASSWD" ]; }
          { command = "/run/current-system/sw/bin/poweroff"; options = [ "NOPASSWD" ]; }
        ];
      }
    ];

    # PipeWire services — run permanently (disable socket activation)
    systemd.user.services.pipewire = {
      unitConfig = {
        X-OnlyByActivation = mkForce false;
        Requires = mkForce [ "dbus.service" ];
      };
      wantedBy = [ "default.target" ];
    };
    systemd.user.services.wireplumber = {
      unitConfig.X-OnlyByActivation = mkForce false;
      wantedBy = [ "default.target" ];
      requires = [ "pipewire.service" ];
    };
    systemd.user.services.pipewire-pulse = {
      unitConfig = {
        X-OnlyByActivation = mkForce false;
        Requires = mkForce [ ];
      };
      wantedBy = [ "default.target" ];
      requires = [ "pipewire.service" ];
      serviceConfig = {
        KillMode = mkForce "mixed";
        TimeoutStopSec = mkForce 0;
      };
    };

    # Apply audio settings from config at boot
    systemd.user.services.apply-audio-config = {
      description = "Apply audio settings from config";
      after = [ "wireplumber.service" "pipewire-pulse.service" ];
      wantedBy = [ "default.target" ];
      path = with pkgs; [ pulseaudio gawk ];
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
        ExecStart = [
          (pkgs.writeShellScript "sinksonic-set-volume" ''
            set -eu
            SINK=$(pactl list sinks short 2>/dev/null | head -1 | awk '{print $2}')
            if [ -n "$SINK" ]; then
              pactl set-sink-volume "$SINK" 100%
              pactl set-sink-mute "$SINK" 0
            else
              echo "WARNING: No ALSA sink found — volume not set"
            fi
          '')
          (pkgs.writeShellScript "sinksonic-set-quantum" ''
            set -eu
            QV=$(grep -v '^\s*#' /data/sinksonic.yaml 2>/dev/null | grep buffer_size | head -1 | sed "s/.*buffer_size: *//")
            if [ -n "$QV" ]; then
              pw-metadata -n settings 0 clock.force-quantum "$QV" 2>/dev/null || true
              logger -t sinksonic-quantum "Set force-quantum to $QV"
            else
              pw-metadata -n settings 0 clock.force-quantum ${toString cfg.bufferSize} 2>/dev/null || true
              logger -t sinksonic-quantum "Fallback: set force-quantum to ${toString cfg.bufferSize}"
            fi
          '')
        ];
      };
    };

    ##############################################################################
    # Web UI
    ##############################################################################
    systemd.services."sinksonic-webui" = mkIf cfg.webui.enable {
      description = "SinkSonic Web UI";
      after = [ "network.target" "user@1000.service" ];
      path = with pkgs; [ pipewire pulseaudio wireplumber ];
      serviceConfig = {
        Type = "simple";
        User = sinksonicUser;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        ExecStart = "${cfg.webui.package}/bin/sinksonic-webui";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "LISTEN_ADDR=0.0.0.0"
          "LISTEN_PORT=${toString cfg.webui.port}"
          "CONFIG_PATH=/data/sinksonic.yaml"
          "XDG_RUNTIME_DIR=/run/user/1000"
          "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
        ];
      };
      wantedBy = [ "multi-user.target" ];
    };

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
      wpa_supplicant
    ];
  };
}
