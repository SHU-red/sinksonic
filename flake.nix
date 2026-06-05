{
  description = "SinkSonic - Declarative network audio sink for Raspberry Pi 3B";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }:
    let
      hostPkgs = import nixpkgs { system = "x86_64-linux"; };

      # Go webui — cross-compiled on x86_64 for aarch64 using plain Go cross-compilation.
      # Go's native cross-compiler handles GOARCH=arm64 with no QEMU or external toolchain.
      webui = hostPkgs.stdenv.mkDerivation {
        pname = "sinksonic-webui";
        version = "0.1.0";
        src = ./webui;
        nativeBuildInputs = [ hostPkgs.go ];
        buildPhase = ''
          CGO_ENABLED=0 GOARCH=arm64 go build -ldflags="-X main.buildVersion=${self.rev or self.dirtyRev or "dev"}" -o sinksonic-webui .
        '';
        installPhase = ''
          mkdir -p $out/bin
          cp sinksonic-webui $out/bin/
        '';
      };

      piConfig = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit webui; };
        modules = [
          ./nixos/configuration.nix
          nixos-hardware.nixosModules.raspberry-pi-3
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
        ];
      };
    in
    {
      nixosConfigurations."sinksonic" = piConfig;

      # SD image — accessible from x86_64 host with --extra-platforms aarch64-linux
      packages."x86_64-linux".sd-image = piConfig.config.system.build.sdImage;
      packages."aarch64-linux".sd-image = piConfig.config.system.build.sdImage;
      packages."x86_64-linux".default = self.packages."x86_64-linux".sd-image;
    };
}
