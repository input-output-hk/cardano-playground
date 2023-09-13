{
  inputs,
  config,
  lib,
  moduleWithSystem,
  ...
}: let
  inherit (config.flake) nixosModules nixosConfigurations;
in {
  flake.colmena = let
    # Region defs:
    eu-central-1.aws.region = "eu-central-1";
    eu-west-1.aws.region = "eu-west-1";
    us-east-2.aws.region = "us-east-2";

    # Instance defs:
    t3a-small.aws.instance.instance_type = "t3a.small";

    # Base cardano-node-service
    inherit (config.flake.cardano-parts.cluster.group.default.meta) cardano-node-service;

    # Cardano group assignments:
    groupPreprod = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preprod;};
    groupPreview = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preview;};
    groupSanchonet = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.sanchonet;};

    topology = nixos: let
      inherit (nixos.config.cardano-parts.cluster.group.meta) environmentName;
      inherit (nixos.config.cardano-parts.perNode.lib) cardanoLib topologyLib;
      inherit (cardanoLib.environments.${environmentName}) edgeNodes;
    in {
      services.cardano-node = {
        producers = topologyLib.topoSimpleMax nixos.name nixos.nodes 3;
        publicProducers = topologyLib.p2pEdgeNodes edgeNodes;
      };
    };

    # Block producer secrets
    bp = {imports = [inputs.cardano-parts.nixosModules.block-producer];};

    preRelease = moduleWithSystem ({system}: {
      cardano-parts.perNode = {
        lib.cardanoLib = config.flake.cardano-parts.pkgs.special.cardanoLibNg system;

        # Until upstream parts ng has capkgs version, use local flake pins
        # This also requires that we've set ng packages comprising cardano-node-pkgs to our local ng pin.
        pkgs.cardano-node-pkgs = config.flake.cardano-parts.pkgs.special.cardano-node-pkgs-ng system;
      };
    });

    # Helper defs:
    # delete.aws.instance.count = 0;

    # Helper fns:
    ebs = size: {aws.instance.root_block_device.volume_size = lib.mkDefault size;};
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
      inputs.cardano-parts.nixosModules.cardano-node-group
      inputs.cardano-parts.nixosModules.cardano-parts
      nixosModules.common
      topology
    ];

    # Simulate world networks with just a relay setup:
    # ---------------------------------------------------------------------------------------------------------
    # Preprod, two-thirds on release tag, one-third on pre-release tag
    preprod-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) groupPreprod cardano-node-service];};
    preprod-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) groupPreprod cardano-node-service];};
    preprod-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) groupPreprod cardano-node-service preRelease];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Preview, one-third on release tag, two-thirds on pre-release tag
    preview-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) groupPreview cardano-node-service];};
    preview-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) groupPreview cardano-node-service preRelease];};
    preview-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) groupPreview cardano-node-service preRelease];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Sanchonet, pre-release
    sanchonet-bp-a-1 = {imports = [us-east-2 t3a-small (ebs 40) groupSanchonet cardano-node-service bp];};
    # sanchonet-bp-a-1 = {imports = [us-east-2 t3a-small (ebs 40) groupSanchonet cardano-node-service bp];};
    sanchonet-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) groupSanchonet cardano-node-service];};
    sanchonet-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) groupSanchonet cardano-node-service];};
    sanchonet-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) groupSanchonet cardano-node-service];};
    # ---------------------------------------------------------------------------------------------------------
  };
}
