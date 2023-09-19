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
    eu-central-1.aws.region = "eu-central-1";
    eu-west-1.aws.region = "eu-west-1";
    us-east-2.aws.region = "us-east-2";

    # Instance defs:
    t3a-small.aws.instance.instance_type = "t3a.small";

    # Helper fns:
    ebs = size: {aws.instance.root_block_device.volume_size = lib.mkDefault size;};

    # Helper defs:
    # delete.aws.instance.count = 0;

    # Cardano group assignments:
    preprod1 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preprod1;};
    # preprod2 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preprod2;};
    # preprod3 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preprod3;};

    preview1 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preview1;};
    # preview2 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preview2;};
    # preview3 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.preview3;};

    sanchonet1 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.sanchonet1;};
    sanchonet2 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.sanchonet2;};
    # sanchonet3 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.sanchonet3;};

    shelley-qa1 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.shelley-qa1;};
    # shelley-qa2 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.shelley-qa2;};
    # shelley-qa3 = {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.group.shelley-qa3;};

    # Cardano-node modules for group deployment
    node = {
      imports = [
        # Base cardano-node service
        config.flake.cardano-parts.cluster.group.default.meta.cardano-node-service

        # Config for cardano-node group deployments
        inputs.cardano-parts.nixosModules.module-cardano-node-group

        # Default group deployment topology
        topoSimple
      ];
    };

    # Profiles
    topoSimple = {imports = [inputs.cardano-parts.nixosModules.profile-topology-simple];};
    # pre = {imports = [inputs.cardano-parts.nixosModules.profile-pre-release];};

    # Roles
    rel = {imports = [inputs.cardano-parts.nixosModules.role-relay];};
    bp = {imports = [inputs.cardano-parts.nixosModules.role-block-producer];};
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
      inputs.cardano-parts.nixosModules.module-cardano-parts
      inputs.cardano-parts.nixosModules.module-common
      nixosModules.common
    ];

    # Setup cardano-world networks:
    # ---------------------------------------------------------------------------------------------------------
    # Preprod, two-thirds on release tag, one-third on pre-release tag
    preprod1-bp-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preprod1 node];}; # TODO: add bp role
    preprod1-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preprod1 node rel];};
    preprod1-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preprod1 node rel];};
    preprod1-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) preprod1 node rel];};

    # preprod2-bp-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preprod2 node];};          # TODO: add bp role
    # preprod2-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preprod2 node rel];};
    # preprod2-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preprod2 node rel];};
    # preprod2-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) preprod2 node rel];};

    # preprod3-bp-c-1 = {imports = [us-east2 t3a-small (ebs 40) preprod3 node pre];};       # TODO: add bp role
    # preprod3-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preprod3 node rel pre];};
    # preprod3-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preprod3 node rel pre];};
    # preprod3-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) preprod3 node rel pre];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Preview, one-third on release tag, two-thirds on pre-release tag
    preview1-bp-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preview1 node];}; # TODO: add bp role
    preview1-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preview1 node rel];};
    preview1-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preview1 node rel];};
    preview1-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) preview1 node rel];};

    # preview2-bp-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preview2 node pre];};      # TODO: add bp role
    # preview2-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preview2 node rel pre];};
    # preview2-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preview2 node rel pre];};
    # preview2-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) preview2 node rel pre];};

    # preview3-bp-c-1 = {imports = [us-east2 t3a-small (ebs 40) preview3 node pre];};       # TODO: add bp role
    # preview3-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) preview3 node rel pre];};
    # preview3-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) preview3 node rel pre];};
    # preview3-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) preview3 node rel pre];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Sanchonet, pre-release
    sanchonet1-bp-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) sanchonet1 node bp];};
    sanchonet1-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) sanchonet1 node rel];};
    sanchonet1-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) sanchonet1 node rel];};
    sanchonet1-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) sanchonet1 node rel];};

    sanchonet2-bp-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) sanchonet2 node];}; # TODO: add bp role
    sanchonet2-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) sanchonet2 node rel];};
    sanchonet2-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) sanchonet2 node rel];};
    sanchonet2-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) sanchonet2 node rel];};

    # sanchonet3-bp-c-1 = {imports = [us-east-2 t3a-small (ebs 40) sanchonet3 node];};      # TODO: add bp role
    # sanchonet3-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) sanchonet3 node rel];};
    # sanchonet3-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) sanchonet3 node rel];};
    # sanchonet3-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) sanchonet3 node rel];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Shelley-qa, pre-release
    shelley-qa1-bp-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) shelley-qa1 node];}; # TODO: add bp role
    shelley-qa1-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) shelley-qa1 node rel];};

    # shelley-qa2-bp-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) shelley-qa2 node];};    # TODO: add bp role
    # shelley-qa2-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) shelley-qa2 node rel];};

    # shelley-qa3-bp-c-1 = {imports = [us-east-2 t3a-small (ebs 40) shelley-qa3 node];};    # TODO: add bp role
    # shelley-qa3-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) shelley-qa3 node rel];};
    # ---------------------------------------------------------------------------------------------------------
  };
}
