{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (config.flake) nixosModules;
in {
  flake.colmena = let
    # Region defs:
    eu-central-1.aws.region = "eu-central-1";

    # Instance defs:
    t3a-small.aws.instance.instance_type = "t3a.small";

    # OS defs:
    nixos-23-05.system.stateVersion = "23.05";

    # Wg defs:
    # wireguardIps = {
    #   eu-central-1 = "10.200.0";
    # };

    # wireguard = region: suffix: {
    #   networking.wireguard.interfaces.wg0.ips = ["${wireguardIps.${region}}.${toString suffix}/32"];
    # };

    # Helper defs:
    # delete.aws.instance.count = 0;

    # Helper fns:
    ebs = size: {aws.instance.root_block_device.volume_size = lib.mkDefault size;};
    # mkNode = num: region: imports: let
    #   shortRegion = lib.substring 0 2 region.aws.region;
    #   suffix = lib.fixedWidthNumber 2 num;
    #   wg = wireguard region.aws.region (num + 1);
    # in {
    #   "client-${shortRegion}-${suffix}" = {imports = [region (volume 60) wg] ++ imports;};
    # };
    # mkNodes = count: region: imports:
    #   lib.foldl' lib.recursiveUpdate {} (
    #     lib.genList (num: mkNode (num + 1) region imports) count
    #   );
  in {
    meta.nixpkgs = import inputs.nixpkgs {
      system = "x86_64-linux";
    };

    defaults.imports = [
      inputs.cardano-parts.nixosModules.aws-ec2
      inputs.cardano-parts.nixosModules.common
      nixosModules.common
      nixos-23-05
    ];

    play-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40)];};
  };
}
