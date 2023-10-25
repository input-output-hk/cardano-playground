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
    t3a-micro.aws.instance.instance_type = "t3a.micro";
    t3a-small.aws.instance.instance_type = "t3a.small";
    t3a-medium.aws.instance.instance_type = "t3a.medium";
    m5a-large.aws.instance.instance_type = "m5a.large";
    # r5-xlarge.aws.instance.instance_type = "r5.xlarge";
    r5-2xlarge.aws.instance.instance_type = "r5.2xlarge";

    # Helper fns:
    ebs = size: {aws.instance.root_block_device.volume_size = lib.mkDefault size;};

    # Helper defs:
    # delete.aws.instance.count = 0;

    # Cardano group assignments:
    group = name: {cardano-parts.cluster.group = config.flake.cardano-parts.cluster.groups.${name};};

    # Cardano-node modules for group deployment
    node = {
      imports = [
        # Base cardano-node service
        config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service

        # Config for cardano-node group deployments
        inputs.cardano-parts.nixosModules.profile-cardano-node-group
      ];
    };

    # Profiles
    pre = {imports = [inputs.cardano-parts.nixosModules.profile-pre-release];};

    ram8gib = nixos: {
      # On an 8 GiB machine, 7.5 GiB is reported as available in free -h
      services.cardano-node.totalMaxHeapSizeMiB = 5734;
      systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "7G";
    };

    ram4gib = nixos: {
      # On an 4 GiB machine, 3.5 GiB is reported as available in free -h
      services.cardano-node.totalMaxHeapSizeMiB = 2867;
      systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "3G";
    };

    # ram2gibActual = nixos: {
    #   services.cardano-node.totalMaxHeapSizeMiB = 1638;
    #   systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "2G";
    # };

    # ram1p5gibActual = nixos: {
    #   services.cardano-node.totalMaxHeapSizeMiB = 1229;
    #   systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "1536M";
    # };

    # ram2gib = nixos: {
    #   # On an 2 GiB machine, 1.5 GiB is reported as available in free -h
    #   services.cardano-node.totalMaxHeapSizeMiB = 819;
    #   systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "1G";
    # };

    node821 = {
      imports = [
        (nixos: {
          cardano-parts.perNode.pkgs = rec {
            inherit (inputs.cardano-node-821-pre.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;
            cardano-node-pkgs = {
              inherit cardano-cli cardano-node cardano-submit-api;
              inherit (nixos.config.cardano-parts.perNode.lib) cardanoLib;
            };
          };
        })
      ];
    };

    nodeHd = {
      imports = [
        (nixos: {
          cardano-parts.perNode.pkgs = rec {
            inherit (inputs.cardano-node-hd.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;
            cardano-node-pkgs = {
              inherit cardano-cli cardano-node cardano-submit-api;
              inherit (nixos.config.cardano-parts.perNode.lib) cardanoLib;
            };
          };
        })
      ];
    };

    lmdb = {services.cardano-node.extraArgs = ["--lmdb-ledger-db-backend"];};

    smash = {
      imports = [
        config.flake.cardano-parts.cluster.groups.default.meta.cardano-smash-service
        inputs.cardano-parts.nixosModules.profile-cardano-smash
        {services.cardano-smash.acmeEmail = "devops@iohk.io";}
      ];
    };

    # Snapshots: add this to a dbsync machine defn and deploy; remove once the snapshot is restored.
    # Snapshots for mainnet can be found at: https://update-cardano-mainnet.iohk.io/cardano-db-sync/index.html#13.1/
    # snapshot = {services.cardano-db-sync.restoreSnapshot = "$SNAPSHOT_URL";};

    # Topology profiles
    # Note: not including a topology profile will default to edge topology if module profile-cardano-node-group is imported
    topoBp = {imports = [inputs.cardano-parts.nixosModules.profile-cardano-node-topology {services.cardano-node-topology = {role = "bp";};}];};
    topoRel = {imports = [inputs.cardano-parts.nixosModules.profile-cardano-node-topology {services.cardano-node-topology = {role = "relay";};}];};

    # Roles
    bp = {imports = [inputs.cardano-parts.nixosModules.role-block-producer topoBp];};
    rel = {imports = [inputs.cardano-parts.nixosModules.role-relay topoRel];};

    dbsync = {
      imports = [
        config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service
        config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
        inputs.cardano-parts.nixosModules.profile-cardano-db-sync
        inputs.cardano-parts.nixosModules.profile-cardano-node-group
        inputs.cardano-parts.nixosModules.profile-cardano-postgres
      ];
    };

    faucet = {
      imports = [
        # TODO: Module import fixup for local services
        # config.flake.cardano-parts.cluster.groups.default.meta.cardano-faucet-service
        inputs.cardano-parts.nixosModules.service-cardano-faucet

        inputs.cardano-parts.nixosModules.profile-cardano-faucet
        {services.cardano-faucet.acmeEmail = "devops@iohk.io";}
      ];
    };

    previewFaucet = {services.cardano-faucet.serverAliases = ["faucet.preview.play.dev.cardano.org" "faucet.preview.world.dev.cardano.org"];};
    sanchoFaucet = {services.cardano-faucet.serverAliases = ["faucet.sanchonet.play.dev.cardano.org" "faucet.sanchonet.world.dev.cardano.org"];};
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
      inputs.cardano-parts.nixosModules.module-cardano-parts
      inputs.cardano-parts.nixosModules.profile-basic
      inputs.cardano-parts.nixosModules.profile-common
      inputs.cardano-parts.nixosModules.profile-grafana-agent
      nixosModules.common
    ];

    # Setup cardano-world networks:
    # ---------------------------------------------------------------------------------------------------------
    # Preprod, two-thirds on release tag, one-third on pre-release tag
    preprod1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod1") node bp];};
    preprod1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod1") node rel];};
    preprod1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod1") node rel];};
    preprod1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod1") node rel];};
    preprod1-dbsync-a-1 = {imports = [eu-central-1 m5a-large (ebs 40) (group "preprod1") dbsync smash];};
    preprod1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod1") node faucet pre];};

    preprod2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod2") node bp];};
    preprod2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod2") node rel];};
    preprod2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod2") node rel];};
    preprod2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod2") node rel];};

    preprod3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod3") node bp pre];};
    preprod3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod3") node rel pre];};
    preprod3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod3") node rel pre];};
    preprod3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod3") node rel pre];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Preview, one-third on release tag, two-thirds on pre-release tag
    preview1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node bp];};
    preview1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node rel];};
    preview1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview1") node rel];};
    preview1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview1") node rel];};
    preview1-dbsync-a-1 = {imports = [eu-central-1 m5a-large (ebs 40) (group "preview1") dbsync smash];};
    preview1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node faucet pre previewFaucet];};

    preview2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview2") node bp pre];};
    preview2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview2") node rel pre];};
    preview2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview2") node rel pre];};
    preview2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview2") node rel pre];};

    preview3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview3") node bp pre];};
    preview3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview3") node rel pre];};
    preview3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview3") node rel pre];};
    preview3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview3") node rel pre];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Sanchonet, pre-release
    sanchonet1-bp-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "sanchonet1") node bp];};
    sanchonet1-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "sanchonet1") node rel];};
    sanchonet1-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "sanchonet1") node rel];};
    sanchonet1-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "sanchonet1") node rel];};
    sanchonet1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "sanchonet1") dbsync smash];};
    sanchonet1-faucet-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "sanchonet1") node faucet sanchoFaucet];};

    sanchonet2-bp-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "sanchonet2") node bp];};
    sanchonet2-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "sanchonet2") node rel];};
    sanchonet2-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "sanchonet2") node rel];};
    sanchonet2-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "sanchonet2") node rel];};

    sanchonet3-bp-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "sanchonet3") node bp];};
    sanchonet3-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "sanchonet3") node rel];};
    sanchonet3-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "sanchonet3") node rel];};
    sanchonet3-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "sanchonet3") node rel];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Mainnet
    mainnet1-dbsync-a-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync];};
    mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node ram8gib];};
    mainnet1-rel-a-2 = {imports = [eu-central-1 t3a-medium (ebs 300) (group "mainnet1") node nodeHd lmdb ram4gib];};
    mainnet1-rel-a-3 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node nodeHd lmdb ram8gib];};
    mainnet1-rel-a-4 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node node821 ram8gib];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Misc
    misc1-metadata-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "misc1")];};
    # ---------------------------------------------------------------------------------------------------------
  };
}
