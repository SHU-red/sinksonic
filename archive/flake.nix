{
  description = "SinkSonic — Declarative network audio receiver. NixOS module + Pi 3B sd-image + Go web UI.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }:
    let
      forEachSystem = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

      # Web UI builder — works on any architecture.
      # On x86_64 set crossArch for aarch64 image builds;
      # on aarch64 (Pi itself) omit it for native build.
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

      # Cross-compiled webui (x86_64 host → aarch64 image)
      webuiCross = mkWebui { pkgs = import nixpkgs { system = "x86_64-linux"; }; crossArch = "arm64"; };

      # Native webui for each arch
      webuiFor = system: mkWebui { pkgs = import nixpkgs { inherit system; }; };

      # Pi 3B sd-image + nixosConfiguration
      mkPi = webui: nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit webui nixos-hardware nixpkgs; };
        modules = [ ./nixos/image-pi-3b.nix ];
      };
    in
    {
      # Pure NixOS module — import on any system:
      #   imports = [ sinksonic.nixosModules.default ];
      #   services.sinksonic.enable = true;
      nixosModules.default = import ./nixos/module.nix;

      # Pi 3B configuration — for nixos-rebuild on-device:
      #   nixos-rebuild switch --flake github:SHU-red/sinksonic#sinksonic
      nixosConfigurations."sinksonic" = mkPi (webuiFor "aarch64-linux");

      # Per-architecture outputs
      packages = forEachSystem (system: {
        # Web UI binary for direct use
        webui = webuiFor system;

        # sd-image for flashing (buildable from x86_64 with QEMU binfmt)
        sd-image = (mkPi webuiCross).config.system.build.sdImage;
        default = self.packages.${system}.sd-image;
      });
    };
}
