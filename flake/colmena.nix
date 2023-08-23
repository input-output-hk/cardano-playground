{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (config.flake) nixosModules nixosConfigurations;
in {
  flake.colmena = let
    # Region defs:
    ap-southeast-1.aws.region = "ap-southeast-1";
    eu-central-1.aws.region = "eu-central-1";
    eu-west-1.aws.region = "eu-west-1";
    us-east-2.aws.region = "us-east-2";

    # Instance defs:
    t3a-small.aws.instance.instance_type = "t3a.small";

    # Base cardano-node-service
    cardano-node-service = config.flake.cardano-parts.cluster.group.default.meta.cardano-node-service;

    # Cardano group assignments:
    groupDefault = nixos: let
      inherit (nixos.config.cardano-parts.cluster.group.meta) environmentName;
      inherit (nixos.config.cardano-parts.perNode.lib) cardanoLib topologyLib;
      inherit (cardanoLib.environments.${environmentName}) edgeNodes;
    in {
      cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.default;

      services.cardano-node = {
        producers = topologyLib.topoSimpleMax nixos.name nixos.nodes 3;
        publicProducers = topologyLib.p2pEdgeNodes edgeNodes;
      };
    };

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
    meta = {
      nixpkgs = import inputs.nixpkgs {
        system = "x86_64-linux";
      };

      nodeSpecialArgs =
        lib.foldl'
        (acc: node: let
          instanceType = node: nixosConfigurations.${node}.config.aws.instance.instance_type;
        in
          lib.recursiveUpdate acc {
            ${node} = {
              nodeResources = {
                inherit
                  (config.flake.cardano-parts.aws.ec2.spec.${instanceType node})
                  provider
                  coreCount
                  cpuCount
                  memMiB
                  nodeType
                  threadsPerCore
                  ;
              };
            };
          })
        {} (builtins.attrNames nixosConfigurations);
    };

    defaults.imports = [
      inputs.cardano-parts.nixosModules.aws-ec2
      inputs.cardano-parts.nixosModules.basic
      inputs.cardano-parts.nixosModules.cardano-node
      inputs.cardano-parts.nixosModules.cardano-parts
      nixosModules.common
    ];

    # Small "play" network cluster
    play-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) groupDefault cardano-node-service];};
    play-rel-a-2 = {imports = [eu-central-1 t3a-small (ebs 40) groupDefault cardano-node-service];};
    play-rel-a-3 = {imports = [eu-central-1 t3a-small (ebs 40) groupDefault cardano-node-service];};
    play-rel-b-1 = {imports = [us-east-2 t3a-small (ebs 40) groupDefault cardano-node-service];};
    play-rel-c-1 = {imports = [eu-west-1 t3a-small (ebs 40) groupDefault cardano-node-service];};
    play-rel-d-1 = {imports = [ap-southeast-1 t3a-small (ebs 40) groupDefault cardano-node-service];};
  };
}
