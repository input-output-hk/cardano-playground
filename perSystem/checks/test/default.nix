{inputs, ...} @ parts: {
  perSystem = {
    pkgs,
    system,
    lib,
    config,
    ...
  }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.test = inputs.nixpkgs.lib.nixos.runTest ({nodes, ...}: let
        inherit (parts.config.flake.nixosModules) common client;
      in {
        name = "test";

        hostPkgs = pkgs;

        defaults = {lib, ...}: {
          imports = [common];

          networking.wireguard.enable = lib.mkForce false;
        };

        nodes = {
          ci1 = {config, ...}: {
            imports = [client];
            networking.firewall.allowedTCPPorts = [];
          };

          ci2 = {};
        };

        testScript = ''
          ci1.wait_for_unit("nomad.service")
        '';
      });
    };
}
