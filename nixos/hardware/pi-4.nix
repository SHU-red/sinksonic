{ config, lib, pkgs, ... }:

with lib;

{
  ##############################################################################
  # Raspberry Pi 4 hardware configuration
  #
  # Import this alongside nixos-hardware.nixosModules.raspberry-pi-4:
  #   imports = [ ./hardware/pi-4.nix nixos-hardware.nixosModules.raspberry-pi-4 ];
  ##############################################################################

  # Allow firmware for WiFi/BT
  hardware.enableRedistributableFirmware = true;

  # Pi 4 kernel modules
  boot = {
    kernelModules = [
      "bcm2835_codec"
      "snd-bcm2835"            # 3.5mm analog audio output
      "snd-soc-hdmi-codec"     # HDMI digital audio
    ];
  };

  # Enable 3.5mm audio jack
  hardware.raspberry-pi.configtxt.settings.all.dtparam = [ "audio=on" ];
}
