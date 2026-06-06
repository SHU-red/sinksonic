{ config, lib, pkgs, ... }:

with lib;

{
  ##############################################################################
  # Raspberry Pi 3B hardware configuration
  #
  # Import this alongside nixos-hardware.nixosModules.raspberry-pi-3:
  #   imports = [ ./hardware/pi-3b.nix nixos-hardware.nixosModules.raspberry-pi-3 ];
  ##############################################################################

  # Allow firmware for WiFi/BT
  hardware.enableRedistributableFirmware = true;

  # Pi 3B kernel modules
  boot = {
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    kernelModules = [
      "bcm2835_codec"          # Video codec (needed for VCHIQ)
      "smsc95xx"               # USB Ethernet (LAN9512 on Pi 3B)
      "snd-bcm2835"            # 3.5mm analog audio output
      "snd-soc-hdmi-codec"     # HDMI digital audio
    ];
  };

  # Enable 3.5mm audio jack via GPU firmware
  hardware.raspberry-pi.configtxt.settings.all.dtparam = [ "audio=on" ];
}
