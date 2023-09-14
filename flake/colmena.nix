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

    # Cardano group assignments:
    preprod = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preprod;};
    preview = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preview;};
    sanchonet = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.sanchonet;};

    # Helper fns:
    ebs = size: {aws.instance.root_block_device.volume_size = lib.mkDefault size;};

    # Cardano-node modules for group deployment
    node = {
      imports = [
        # Base cardano-node service
        config.flake.cardano-parts.cluster.group.default.meta.cardano-node-service

        # Config for cardano-node group deployments
        inputs.cardano-parts.nixosModules.module-cardano-node-group

        # Config enabling easy perNode customization
        inputs.cardano-parts.nixosModules.module-cardano-parts

        # Default group deployment topology
        topology
      ];
    };

    # Relay simple topology
    topology = nixos: let
      inherit (nixos.config.cardano-parts.cluster.group.meta) environmentName;
      inherit (nixos.config.cardano-parts.perNode.lib) cardanoLib topologyLib;
      inherit (cardanoLib.environments.${environmentName}) edgeNodes;
    in {
      services.cardano-node = {
        producers = topologyLib.topoSimple nixos.name nixos.nodes;
        publicProducers = topologyLib.p2pEdgeNodes edgeNodes;
      };
    };

    # Relay
    rel = nixos: let
      inherit (nixos.config.cardano-parts.perNode.meta) cardanoNodePort;
    in {
      networking.firewall = {allowedTCPPorts = [cardanoNodePort];};
    };

    # Block producer secrets and topology modification
    bp = nixos: {
      imports = [inputs.cardano-parts.nixosModules.role-block-producer];

      services.cardano-node = {
        publicProducers = nixos.lib.mkForce [];
        usePeersFromLedgerAfterSlot = -1;
      };
    };

    # Use the pre-release cardano-node-pkgs and library
    pre = moduleWithSystem ({system}: {
      cardano-parts.perNode = {
        lib.cardanoLib = config.flake.cardano-parts.pkgs.special.cardanoLibNg system;

        # Until upstream parts ng has capkgs version, use local flake pins
        # This also requires that we've set ng packages comprising cardano-node-pkgs to our local ng pin.
        pkgs.cardano-node-pkgs = config.flake.cardano-parts.pkgs.special.cardano-node-pkgs-ng system;
      };
    });
    # Helper defs:
    # delete.aws.instance.count = 0;
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
      inputs.cardano-parts.nixosModules.module-aws-ec2
      inputs.cardano-parts.nixosModules.module-basic
      inputs.cardano-parts.nixosModules.module-common
      nixosModules.common
    ];

    # Simulate world networks with just a relay setup:
    # ---------------------------------------------------------------------------------------------------------
    # Preprod, two-thirds on release tag, one-third on pre-release tag
    preprod-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preprod node rel];};
    preprod-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preprod node rel];};
    preprod-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) preprod node rel pre];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Preview, one-third on release tag, two-thirds on pre-release tag
    preview-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preview node rel];};
    preview-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preview node rel pre];};
    preview-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) preview node rel pre];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Sanchonet, pre-release
    sanchonet-bp-a-1 = {imports = [us-east-2 t3a-small (ebs 40) sanchonet node bp];};
    sanchonet-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) sanchonet node rel];};
    sanchonet-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) sanchonet node rel];};
    sanchonet-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) sanchonet node rel];};
    # ---------------------------------------------------------------------------------------------------------
  };
}
