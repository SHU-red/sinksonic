# SinkSonic on any x86_64 NixOS desktop — reference configuration
#
# Add to your flake inputs:
#   sinksonic.url = "github:SHU-red/sinksonic";
#
# Then in your nixosConfiguration:
#   nixosConfigurations.desktop = nixpkgs.lib.nixosSystem {
#     system = "x86_64-linux";
#     modules = [
#       sinksonic.nixosModules.default
#       {
#         services.sinksonic = {
#           enable = true;
#           webui.package = sinksonic.packages.x86_64-linux.webui;
#           # Optional: adjust for your network
#           bufferSize = 2048;
#         };
#       }
#     ];
#   };

# This file intentionally empty — the module needs no extra config on desktop.
# SinkSonic just works on any NixOS machine.
{ }
