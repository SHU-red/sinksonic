{
  description = "SinkSonic — Declarative network audio receiver. NixOS module + RPi 3B sd-image.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }:
    let
      hostPkgs = import nixpkgs { system = "x86_64-linux"; };
      armPkgs  = import nixpkgs { system = "aarch64-linux"; };

      # Web UI builder — works on any architecture. On x86_64 set crossArch
      # for aarch64; on aarch64 (Pi itself), omit it for native build.
      mkWebui = { pkgs, crossArch ? null }: pkgs.stdenv.mkDerivation {
        pname = "sinksonic-webui";
        version = "0.1.0";
        src = ./webui;
        nativeBuildInputs = [ pkgs.go ];
        buildPhase = ''
          CGO_ENABLED=0 ${if crossArch != null then "GOARCH=${crossArch}" else ""} go build \
            -ldflags="-X main.buildVersion=${self.rev or self.dirtyRev or "dev"}" \
            -o sinksonic-webui .
        '';
        installPhase = ''
          mkdir -p $out/bin
          cp sinksonic-webui $out/bin/
        '';
      };

      # Cross-compiled from x86_64 for the sd-image builder
      webuiCross = mkWebui { pkgs = hostPkgs; crossArch = "arm64"; };

      # Native aarch64 for nixos-rebuild on the Pi itself
      webuiNative = mkWebui { pkgs = armPkgs; };

      # Pi 3B sd-image configuration (uses cross-compiled webui for image build)
      piSdImage = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          webui = webuiCross;
          inherit nixos-hardware nixpkgs;
        };
        modules = [ ./nixos/image.nix ];
      };

      # Pi 3B configuration for nixos-rebuild on-device (uses native webui)
      piNative = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          webui = webuiNative;
          inherit nixos-hardware nixpkgs;
        };
        modules = [ ./nixos/image.nix ];
      };
    in
    {
      # Reusable NixOS module — add to any NixOS system:
      #   imports = [ sinksonic.nixosModules.default ];
      #   services.sinksonic.enable = true;
      nixosModules.default = import ./nixos/module.nix;

      # nixosConfigurations — for nixos-rebuild on the Pi itself
      # SSH into Pi and run:
      #   nixos-rebuild switch --flake github:shured/sinksonic#sinksonic
      nixosConfigurations."sinksonic" = piNative;

      # SD image package (for the build host, uses cross-compiled webui)
      packages."x86_64-linux".sd-image = piSdImage.config.system.build.sdImage;
      packages."x86_64-linux".default = self.packages."x86_64-linux".sd-image;
      packages."aarch64-linux".sd-image = piSdImage.config.system.build.sdImage;

      # Direct access to webui binaries
      packages."x86_64-linux".webui = webuiCross;
      packages."aarch64-linux".webui = webuiNative;
    };
}
