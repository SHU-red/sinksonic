{
  description = "SinkSonic — Declarative network audio receiver. NixOS module + Go web UI.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      # mkWebui builds the Go web dashboard for any architecture.
      # On x86_64 the module consumer's pkgs produces an x86_64 binary;
      # on aarch64 it produces an aarch64 binary — Go handles this natively.
      mkWebui = pkgs: pkgs.stdenv.mkDerivation {
        pname = "sinksonic-webui";
        version = "0.1.0";
        src = ./webui;
        nativeBuildInputs = [ pkgs.go ];
        buildPhase = ''
          CGO_ENABLED=0 go build \
            -ldflags="-X main.buildVersion=${self.rev or self.dirtyRev or "dev"}" \
            -o sinksonic-webui .
        '';
        installPhase = ''
          mkdir -p $out/bin
          cp sinksonic-webui $out/bin/
        '';
      };

      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # The module — import on any NixOS system:
      #   imports = [ sinksonic.nixosModules.default ];
      #   services.sinksonic.enable = true;
      nixosModules.default = import ./nixos/module.nix;

      # Web UI binaries per architecture — users set
      # services.sinksonic.webui.package to one of these.
      packages = forAllSystems (system: {
        webui = mkWebui (import nixpkgs { inherit system; });
      });
    };
}
