{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (config.flake) nixosModules nixosConfigurations;
  inherit (config.flake.cardano-parts.cluster.infra.aws) domain;
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
    # r5-large.aws.instance.instance_type = "r5.large";
    r5-xlarge.aws.instance.instance_type = "r5.xlarge";
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

    ram5gibActual = nixos: {
      # The amount required for doing chain re-validation after a failed startup; less crashes
      services.cardano-node.totalMaxHeapSizeMiB = 4096;
      systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "5G";
    };

    ram8gib = nixos: {
      # On an 8 GiB machine, 7.5 GiB is reported as available in free -h
      services.cardano-node.totalMaxHeapSizeMiB = 5734;
      systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "7G";
    };

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

    webserver = {
      imports = [
        inputs.cardano-parts.nixosModules.profile-cardano-webserver
        {
          services.cardano-webserver.acmeEmail = "devops@iohk.io";
          # Until book.world.dev.cardano.org has CNAME to play
          services.nginx.virtualHosts.tlsTerminator.serverAliases = lib.mkForce ["book.play.dev.cardano.org"];
        }
      ];
    };

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
        {services.cardano-postgres.enablePsqlrc = true;}
      ];
    };

    preprodSmash = {services.cardano-smash.serverAliases = lib.flatten (map (e: ["${e}.${domain}" "${e}.world.dev.cardano.org"]) ["preprod-smash" "preprod-explorer"]);};
    previewSmash = {services.cardano-smash.serverAliases = lib.flatten (map (e: ["${e}.${domain}" "${e}.world.dev.cardano.org"]) ["preview-smash" "preview-explorer"]);};
    privateSmash = {services.cardano-smash.serverAliases = lib.flatten (map (e: ["${e}.${domain}"]) ["private-smash" "private-explorer"]);};
    sanchoSmash = {services.cardano-smash.serverAliases = lib.flatten (map (e: ["${e}.${domain}" "${e}.world.dev.cardano.org"]) ["sanchonet-smash" "sanchonet-explorer"]);};
    shelleySmash = {services.cardano-smash.serverAliases = lib.flatten (map (e: ["${e}.${domain}"]) ["shelley-qa-smash" "shelley-qa-explorer"]);};

    faucet = {
      imports = [
        # TODO: Module import fixup for local services
        # config.flake.cardano-parts.cluster.groups.default.meta.cardano-faucet-service
        inputs.cardano-parts.nixosModules.service-cardano-faucet

        inputs.cardano-parts.nixosModules.profile-cardano-faucet
        {services.cardano-faucet.acmeEmail = "devops@iohk.io";}
      ];
    };

    preprodFaucet = {services.cardano-faucet.serverAliases = ["faucet.preprod.${domain}" "faucet.preprod.world.dev.cardano.org"];};
    previewFaucet = {services.cardano-faucet.serverAliases = ["faucet.preview.${domain}" "faucet.preview.world.dev.cardano.org"];};
    privateFaucet = {services.cardano-faucet.serverAliases = ["faucet.private.${domain}"];};
    sanchoFaucet = {services.cardano-faucet.serverAliases = ["faucet.sanchonet.${domain}" "faucet.sanchonet.world.dev.cardano.org"];};
    shelleyFaucet = {services.cardano-faucet.serverAliases = ["faucet.shelley-qa.${domain}"];};

    metadata = {
      imports = [
        config.flake.cardano-parts.cluster.groups.default.meta.cardano-metadata-service
        inputs.cardano-parts.nixosModules.profile-cardano-metadata
        inputs.cardano-parts.nixosModules.profile-cardano-postgres
        {
          services.cardano-metadata.acmeEmail = "devops@iohk.io";
          services.cardano-metadata.serverAliases = ["metadata.${domain}" "metadata.world.dev.cardano.org"];
        }
      ];
    };

    mkWorldRelayMig = worldPort: {
      networking.firewall = {
        allowedTCPPorts = [worldPort];
        extraCommands = "iptables -t nat -A PREROUTING -i ens5 -p tcp --dport ${toString worldPort} -j REDIRECT --to-port 3001";
        extraStopCommands = "iptables -t nat -D PREROUTING -i ens5 -p tcp --dport ${toString worldPort} -j REDIRECT --to-port 3001 || true";
      };
    };

    # Preprod to be applied once preprod pools finish their retirement forging epoch and a CNAME redirect is applied
    preprodRelMig = mkWorldRelayMig 30000;
    previewRelMig = mkWorldRelayMig 30002;
    sanchoRelMig = mkWorldRelayMig 30004;

    # Allow legacy group incoming connections on bps if non-p2p testing is required
    # mkBpLegacyFwRules = nodeNameList: {
    #   networking.firewall = let
    #     sources = lib.concatMapStringsSep "," (n: "${n}.${domain}") nodeNameList;
    #   in {
    #     extraCommands = "iptables -t filter -I nixos-fw -i ens5 -p tcp -m tcp -s ${sources} --dport 3001 -j nixos-fw-accept";
    #     extraStopCommands = "iptables -t filter -D nixos-fw -i ens5 -p tcp -m tcp -s ${sources} --dport 3001 -j nixos-fw-accept || true";
    #   };
    # };

    # disableP2p = {services.cardano-node.useNewTopology = false;};

    # sancho1bpLegacy = mkBpLegacyFwRules ["sanchonet1-rel-a-1" "sanchonet1-rel-b-1" "sanchonet1-rel-c-1"];
    # sancho2bpLegacy = mkBpLegacyFwRules ["sanchonet2-rel-a-1" "sanchonet2-rel-b-1" "sanchonet2-rel-c-1"];
    # sancho3bpLegacy = mkBpLegacyFwRules ["sanchonet3-rel-a-1" "sanchonet3-rel-b-1" "sanchonet3-rel-c-1"];

    multiInst = {services.cardano-node.instances = 2;};

    netDebug = {
      services.cardano-node = {
        useNewTopology = false;
        extraNodeConfig = {
          TraceMux = true;
          TraceConnectionManagerTransitions = true;
          TraceDebugPeerSelection = true;

          options.mapSeverity = {
            "cardano.node.ConnectionManager" = "Debug";
            "cardano.node.ConnectionManagerTransition" = "Debug";
            "cardano.node.PeerSelection" = "Info";
            "cardano.node.DebugPeerSelection" = "Debug";
            "cardano.node.PeerSelectionActions" = "Debug";
            "cardano.node.Handshake" = "Debug";
            "cardano.node.Mux" = "Info";
            "cardano.node.ChainSyncProtocol" = "Error";
            "cardano.node.InboundGovernor" = "Debug";
            "cardano.node.resources" = "Notice";
          };
        };
      };
    };
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
    preprod1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod1") node rel preprodRelMig];};
    preprod1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod1") node rel preprodRelMig];};
    preprod1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod1") node rel preprodRelMig];};
    preprod1-dbsync-a-1 = {imports = [eu-central-1 m5a-large (ebs 40) (group "preprod1") dbsync smash preprodSmash];};
    preprod1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod1") node faucet pre preprodFaucet];};

    preprod2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod2") node bp];};
    preprod2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod2") node rel preprodRelMig];};
    preprod2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod2") node rel preprodRelMig];};
    preprod2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod2") node rel preprodRelMig];};

    preprod3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod3") node bp pre];};
    preprod3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod3") node rel pre preprodRelMig];};
    preprod3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod3") node rel pre preprodRelMig];};
    preprod3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod3") node rel pre preprodRelMig];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Preview, one-third on release tag, two-thirds on pre-release tag
    preview1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node bp];};
    preview1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node rel previewRelMig];};
    preview1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview1") node rel previewRelMig];};
    preview1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview1") node rel previewRelMig];};
    preview1-dbsync-a-1 = {imports = [eu-central-1 m5a-large (ebs 40) (group "preview1") dbsync smash previewSmash];};
    preview1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node faucet pre previewFaucet];};

    preview2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview2") node bp pre];};
    preview2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview2") node rel pre previewRelMig];};
    preview2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview2") node rel pre previewRelMig];};
    preview2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview2") node rel pre previewRelMig];};

    preview3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview3") node bp pre];};
    preview3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview3") node rel pre previewRelMig];};
    preview3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview3") node rel pre previewRelMig];};
    preview3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview3") node rel pre previewRelMig];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Private, pre-release
    private1-bp-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "private1") node bp];};
    private1-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "private1") node rel];};
    private1-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "private1") node rel];};
    private1-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "private1") node rel];};
    private1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "private1") dbsync smash privateSmash];};
    private1-faucet-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "private1") node faucet privateFaucet];};

    private2-bp-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "private2") node bp];};
    private2-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "private2") node rel];};
    private2-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "private2") node rel];};
    private2-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "private2") node rel];};

    private3-bp-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "private3") node bp];};
    private3-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "private3") node rel];};
    private3-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "private3") node rel];};
    private3-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "private3") node rel];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Sanchonet, pre-release
    sanchonet1-bp-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "sanchonet1") node bp];};
    sanchonet1-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "sanchonet1") node rel sanchoRelMig netDebug];};
    sanchonet1-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) (group "sanchonet1") node rel sanchoRelMig];};
    sanchonet1-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) (group "sanchonet1") node rel sanchoRelMig];};
    sanchonet1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "sanchonet1") dbsync smash sanchoSmash];};
    sanchonet1-faucet-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "sanchonet1") node faucet sanchoFaucet];};
    sanchonet1-test-a-1 = {imports = [eu-central-1 r5-xlarge (ebs 40) (group "sanchonet1") node multiInst];};

    sanchonet2-bp-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "sanchonet2") node bp];};
    sanchonet2-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "sanchonet2") node rel sanchoRelMig netDebug];};
    sanchonet2-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) (group "sanchonet2") node rel sanchoRelMig];};
    sanchonet2-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) (group "sanchonet2") node rel sanchoRelMig];};

    sanchonet3-bp-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "sanchonet3") node bp];};
    sanchonet3-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "sanchonet3") node rel sanchoRelMig];};
    sanchonet3-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) (group "sanchonet3") node rel sanchoRelMig];};
    sanchonet3-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) (group "sanchonet3") node rel sanchoRelMig];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Shelley-qa, pre-release
    shelley-qa1-bp-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "shelley-qa1") node bp];};
    shelley-qa1-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "shelley-qa1") node rel];};
    shelley-qa1-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "shelley-qa1") node rel];};
    shelley-qa1-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "shelley-qa1") node rel];};
    shelley-qa1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "shelley-qa1") dbsync smash shelleySmash];};
    shelley-qa1-faucet-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "shelley-qa1") node faucet shelleyFaucet];};

    shelley-qa2-bp-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "shelley-qa2") node bp];};
    shelley-qa2-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "shelley-qa2") node rel];};
    shelley-qa2-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "shelley-qa2") node rel];};
    shelley-qa2-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "shelley-qa2") node rel];};

    shelley-qa3-bp-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "shelley-qa3") node bp];};
    shelley-qa3-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "shelley-qa3") node rel];};
    shelley-qa3-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "shelley-qa3") node rel];};
    shelley-qa3-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "shelley-qa3") node rel];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Mainnet
    mainnet1-dbsync-a-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync];};
    mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node ram8gib];};
    mainnet1-rel-a-2 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node nodeHd lmdb ram5gibActual];};
    mainnet1-rel-a-3 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node nodeHd lmdb ram8gib];};
    mainnet1-rel-a-4 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node node821 ram8gib];};
    # ---------------------------------------------------------------------------------------------------------

    # ---------------------------------------------------------------------------------------------------------
    # Misc
    misc1-metadata-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "misc1") metadata];};
    misc1-webserver-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "misc1") webserver];};
    # ---------------------------------------------------------------------------------------------------------
  };
}
