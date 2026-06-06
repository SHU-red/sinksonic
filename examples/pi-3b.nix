# SinkSonic on Raspberry Pi 3B — reference configuration
#
# Add to your flake inputs:
#   sinksonic.url = "github:SHU-red/sinksonic";
#   nixos-hardware.url = "github:NixOS/nixos-hardware/master";
#
# Then create a nixosConfiguration:
#   nixosConfigurations.pi3b = nixpkgs.lib.nixosSystem {
#     system = "aarch64-linux";
#     modules = [
#       sinksonic.nixosModules.default
#       nixos-hardware.nixosModules.raspberry-pi-3
#       ./examples/pi-3b.nix
#       {
#         services.sinksonic.webui.package = sinksonic.packages.aarch64-linux.webui;
#       }
#     ];
#   };

{ config, lib, pkgs, ... }:

{
  # Pi 3B kernel modules for analog + HDMI audio
  boot.kernelModules = [ "snd-bcm2835" "snd-soc-hdmi-codec" ];
  hardware.raspberry-pi.configtxt.settings.all.dtparam = [ "audio=on" ];

  # Read-only root (tmpfs) — protects SD card from wear
  fileSystems."/var"  = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=128M" "mode=0755" ]; };
  fileSystems."/tmp"  = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=64M" "mode=1777" ]; };
  fileSystems."/home" = { device = "tmpfs"; fsType = "tmpfs"; options = [ "size=64M" "mode=0755" ]; };

  # Persistent data partition
  fileSystems."/data" = {
    device = "/dev/disk/by-label/SINKSONIC_DATA";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  networking.hostName = "sinksonic";
  system.stateVersion = "24.05";
}
