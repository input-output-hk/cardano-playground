{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (config.flake) nixosModules nixosConfigurations;
  inherit (config.flake.cardano-parts.cluster.infra.aws) domain;

  cfgGeneric = config.flake.cardano-parts.cluster.infra.generic;
in
  with builtins;
  with lib; {
    flake.colmena = let
      # Region defs:
      eu-central-1.aws.region = "eu-central-1";
      eu-west-1.aws.region = "eu-west-1";
      us-east-2.aws.region = "us-east-2";

      # Instance defs:
      c5ad-large.aws.instance.instance_type = "c5ad.large";
      c6i-xlarge.aws.instance.instance_type = "c6i.xlarge";
      # c6i-12xlarge.aws.instance.instance_type = "c6i.12xlarge";
      m5a-large.aws.instance.instance_type = "m5a.large";
      # m5a-2xlarge.aws.instance.instance_type = "m5a.2xlarge";
      r5-large.aws.instance.instance_type = "r5.large";
      r5-xlarge.aws.instance.instance_type = "r5.xlarge";
      r5-2xlarge.aws.instance.instance_type = "r5.2xlarge";
      t3a-micro.aws.instance.instance_type = "t3a.micro";
      t3a-small.aws.instance.instance_type = "t3a.small";
      t3a-medium.aws.instance.instance_type = "t3a.medium";

      # Helper fns:
      ebs = size: {aws.instance.root_block_device.volume_size = mkDefault size;};
      # ebsIops = iops: {aws.instance.root_block_device.iops = mkDefault iops;};
      # ebsTp = tp: {aws.instance.root_block_device.throughput = mkDefault tp;};
      # ebsHighPerf = recursiveUpdate (ebsIops 10000) (ebsTp 1000);

      # Helper defs:
      disableAlertCount.cardano-parts.perNode.meta.enableAlertCount = false;
      # delete.aws.instance.count = 0;

      # Cardano group assignments:
      group = name: {
        cardano-parts.cluster.group = config.flake.cardano-parts.cluster.groups.${name};

        # Since all machines are assigned a group, this is a good place to include default aws instance tags
        aws.instance.tags = {
          inherit (cfgGeneric) organization tribe function repo;
          environment = config.flake.cardano-parts.cluster.groups.${name}.meta.environmentName;
          group = name;
        };
      };

      # Cardano-node modules for group deployment
      node = {
        imports = [
          # Base cardano-node service
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service

          # Config for cardano-node group deployments
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
        ];
      };

      # Mithril signing config
      mithrilRelay = {imports = [inputs.cardano-parts.nixosModules.profile-mithril-relay];};
      declMRel = node: {services.mithril-signer.relayEndpoint = nixosConfigurations.${node}.config.ips.privateIpv4;};
      declMSigner = node: {services.mithril-relay.signerIp = nixosConfigurations.${node}.config.ips.privateIpv4;};

      # Profiles
      pre = {imports = [inputs.cardano-parts.nixosModules.profile-pre-release];};

      openFwTcp = port: {networking.firewall.allowedTCPPorts = [port];};

      nodeRamPct = ramPercent: nixos: {services.cardano-node.totalMaxHeapSizeMiB = nixos.nodeResources.memMiB * ramPercent / 100;};

      # Historically, this parameter could result in up to 4 times the specified amount of ram being consumed.
      # However, this doesn't seem to be the case anymore.
      varnishRamPct = ramPercent: nixos: {services.cardano-webserver.varnishRamAvailableMiB = nixos.nodeResources.memMiB * ramPercent / 100;};

      ram8gib = nixos: {
        # On an 8 GiB machine, 7.5 GiB is reported as available in free -h
        services.cardano-node.totalMaxHeapSizeMiB = 5734;
        systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "7G";
      };

      nodeHd = {
        imports = [
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics

          (nixos: let
            inherit (nixos.config.cardano-parts.perNode.lib.opsLib) mkCardanoLib;
          in {
            cardano-parts.perNode.lib.cardanoLib = mkCardanoLib "x86_64-linux" inputs.nixpkgs inputs.iohk-nix-9-0-0;
            cardano-parts.perNode.pkgs = {
              inherit (inputs.cardano-node-hd.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;
            };
          })
        ];
      };

      nodeTxDelay = {
        imports = [
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
          {
            cardano-parts.perNode.pkgs = {
              inherit (inputs.cardano-node-tx-delay.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;
            };
          }
        ];
      };

      # tracingUpdate = {
      #   imports = [
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service
      #     inputs.cardano-parts.nixosModules.profile-cardano-node-group
      #     inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
      #     {
      #       cardano-parts.perNode.pkgs = {
      #         inherit (inputs.tracingUpdate.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;
      #       };
      #     }
      #   ];
      # };

      lmdb = {services.cardano-node.extraArgs = ["--lmdb-ledger-db-backend"];};

      smash = {
        imports = [
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-smash-service
          inputs.cardano-parts.nixosModules.profile-cardano-smash
          {services.cardano-smash.acmeEmail = "devops@iohk.io";}
        ];
      };

      # Snapshots: add this to a dbsync machine defn and deploy; remove once the snapshot is restored.
      # Snapshots for mainnet can be found at: https://update-cardano-mainnet.iohk.io/cardano-db-sync/index.html
      # snapshot = {services.cardano-db-sync.restoreSnapshot = "$SNAPSHOT_URL";};

      webserver = {
        imports = [
          inputs.cardano-parts.nixosModules.profile-cardano-webserver
          {
            services.cardano-webserver = {
              acmeEmail = "devops@iohk.io";

              # Always keep the book staging alias present so we aren't making frequent ACME cert requests
              # when temporarily publishing a staging environment and then removing it shortly later.
              serverAliases = ["book-staging.${domain}"];
            };
          }
        ];
      };

      # Topology profiles
      # Note: not including a topology profile will default to edge topology if module profile-cardano-node-group is imported
      topoBp = {imports = [inputs.cardano-parts.nixosModules.profile-cardano-node-topology {services.cardano-node-topology = {role = "bp";};}];};
      topoRel = {imports = [inputs.cardano-parts.nixosModules.profile-cardano-node-topology {services.cardano-node-topology = {role = "relay";};}];};

      # Roles
      bp = {
        imports = [
          inputs.cardano-parts.nixosModules.role-block-producer
          topoBp
          # Disable machine DNS creation for block producers to avoid ip discovery
          {cardano-parts.perNode.meta.enableDns = false;}
        ];
      };
      rel = {imports = [inputs.cardano-parts.nixosModules.role-relay topoRel];};

      dbsync = {
        imports = [
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
          inputs.cardano-parts.nixosModules.profile-cardano-db-sync
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
          inputs.cardano-parts.nixosModules.profile-cardano-postgres
          {services.cardano-node.shareNodeSocket = true;}
          {services.cardano-postgres.enablePsqlrc = true;}
        ];
      };

      # ogmios = {
      #   imports = [
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-ogmios-service
      #     nixosModules.ogmios
      #   ];
      # };

      mithrilRelease = {imports = [nixosModules.mithril-release-pin];};

      dbsyncPub = {
        pkgs,
        config,
        name,
        ...
      }: {
        # Override profile-cardano-postgres defaults to enable public access
        services.postgresql = {
          enableTCPIP = mkForce true;

          authentication = mkForce ''
            local   all all ident        map=explorer-users
            host    all all 127.0.0.1/32 scram-sha-256
            host    all all ::1/128      scram-sha-256
            hostssl all all all          scram-sha-256
          '';

          # Create a tmp user manually after the system has been nixos activated:
          # sudo -iu postgres -- psql
          #   create user <USER> login password '<PASSWORD>'
          #   grant pg_read_all_date to <USER>
          settings = {
            password_encryption = "scram-sha-256";
            ssl = "on";
            ssl_ca_file = "server.crt";
            ssl_cert_file = "server.crt";
            ssl_key_file = "server.key";
          };
        };

        system.activationScripts.pgSelfSignedCert.text = ''
          PG_MAJOR="${head (splitString "." config.services.postgresql.package.version)}"
          TARGET="/var/lib/postgresql/$PG_MAJOR"

          if [ -d "$TARGET" ]; then
            cd "$TARGET"

            if ! [ -s server.key ]; then
              echo "Creating a new postgresl self-signed cert on ${name}..."

              set -x
              rm -f server.*
              ${pkgs.openssl}/bin/openssl req \
                -new \
                -x509 \
                -days 3650 \
                -nodes \
                -subj "/C=DE/O=IOG/OU=SRE/CN=${name}.${domain}" \
                -keyout server.key \
                -out server.crt

              chmod 0400 server.key
              chown postgres:postgres server*
              set +x
            else
              echo "A postgresql self-signed cert exists on ${name}."
            fi
          fi
        '';
      };

      preprodSmash = {services.cardano-smash.serverAliases = flatten (map (e: ["${e}.${domain}" "${e}.world.dev.cardano.org"]) ["preprod-smash" "preprod-explorer"]);};
      previewSmash = {services.cardano-smash.serverAliases = flatten (map (e: ["${e}.${domain}" "${e}.world.dev.cardano.org"]) ["preview-smash" "preview-explorer"]);};
      # privateSmash = {services.cardano-smash.serverAliases = flatten (map (e: ["${e}.${domain}"]) ["private-smash" "private-explorer"]);};
      sanchoSmash = {services.cardano-smash.serverAliases = flatten (map (e: ["${e}.${domain}" "${e}.world.dev.cardano.org"]) ["sanchonet-smash" "sanchonet-explorer"]);};
      shelleySmash = {services.cardano-smash.serverAliases = flatten (map (e: ["${e}.${domain}"]) ["shelley-qa-smash" "shelley-qa-explorer"]);};

      faucet = {
        imports = [
          # TODO: Module import fixup for local services
          # config.flake.cardano-parts.cluster.groups.default.meta.cardano-faucet-service
          inputs.cardano-parts.nixosModules.service-cardano-faucet

          inputs.cardano-parts.nixosModules.profile-cardano-faucet
          {services.cardano-faucet.acmeEmail = "devops@iohk.io";}
          {services.cardano-node.shareNodeSocket = true;}
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

      newMetrics = {
        imports = [
          (
            # Existing tracer service requires a pkgs with commonLib defined in the cardano-node repo flake overlay.
            # We'll import it through flake-compat so we don't need a full flake input just for obtaining commonLib.
            import
            config.flake.cardano-parts.cluster.groups.default.meta.cardano-tracer-service
            (import
              "${config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service}/../../default.nix" {system = "x86_64-linux";})
            .legacyPackages
            .x86_64-linux
          )
          inputs.cardano-parts.nixosModules.profile-cardano-node-new-tracing
        ];
      };

      logRejected = {
        services.cardano-node.extraNodeConfig.TraceOptions = {
          "Mempool" = {
            severity = "Debug";
            detail = "DDetailed";
          };
          # "Mempool.MempoolAttemptAdd" = {
          #   severity = "Debug";
          #   detail = "DDetailed";
          # };
          # "Mempool.MempoolAttemptingSync" = {
          #   severity = "Debug";
          #   detail = "DDetailed";
          # };
          # "Mempool.MempoolLedgerFound" = {
          #   severity = "Debug";
          #   detail = "DDetailed";
          # };
          # "Mempool.MempoolLedgerNotFound" = {
          #   severity = "Debug";
          #   detail = "DDetailed";
          # };
          # "Mempool.MempoolSyncDone" = {
          #   severity = "Debug";
          #   detail = "DDetailed";
          # };
          # "Mempool.MempoolSyncNotNeeded" = {
          #   severity = "Debug";
          #   detail = "DDetailed";
          # };
          "TxSubmission.TxInbound" = {
            severity = "Debug";
            detail = "DDetailed";
          };
          "TxSubmission.TxOutbound" = {
            severity = "Debug";
            detail = "DDetailed";
          };
        };
      };

      traceTxs = {
        services.cardano-node.extraNodeConfig = {
          TraceLocalTxSubmissionProtocol = true;
          TraceLocalTxSubmissionServer = true;
          TraceTxSubmissionProtocol = true;
          TraceTxInbound = true;
          TraceTxOutbound = true;
        };
      };

      # mempoolDisable = {
      #   services.cardano-node.extraNodeConfig.TraceMempool = false;
      # };
      #
      # Ephermeral instance disk storage config for upcoming UTxO-HD/LMDB
      # iDisk = {
      #   fileSystems = {
      #     "/ephemeral" = {
      #       device = "/dev/nvme1n1";
      #       fsType = "ext4";
      #       autoFormat = true;
      #     };
      #   };
      # };
      # p2p and legacy network debugging code
      # netDebug = {
      #   services.cardano-node = {
      #     useNewTopology = false;
      #     extraNodeConfig = {
      #       TraceMux = true;
      #       TraceConnectionManagerTransitions = true;
      #       DebugPeerSelectionInitiator = true;
      #       DebugPeerSelectionInitiatorResponder = true;
      #       options.mapSeverity = {
      #         "cardano.node.DebugPeerSelectionInitiatorResponder" = "Debug";
      #         "cardano.node.ChainSyncProtocol" = "Error";
      #         "cardano.node.ConnectionManager" = "Debug";
      #         "cardano.node.ConnectionManagerTransition" = "Debug";
      #         "cardano.node.DebugPeerSelection" = "Debug";
      #         "cardano.node.Handshake" = "Debug";
      #         "cardano.node.InboundGovernor" = "Debug";
      #         "cardano.node.Mux" = "Info";
      #         "cardano.node.PeerSelectionActions" = "Debug";
      #         "cardano.node.PeerSelection" = "Info";
      #         "cardano.node.resources" = "Notice";
      #       };
      #     };
      #   };
      # };
      #
      minLog = {
        services.cardano-node.extraNodeConfig = {
          # Let's make sure we can at least see the blockHeight in logs and metrics
          TraceChainDb = true;

          # And then shut everything else off
          TraceAcceptPolicy = false;
          TraceConnectionManager = false;
          TraceDiffusionInitialization = false;
          TraceDNSResolver = false;
          TraceDNSSubscription = false;
          TraceErrorPolicy = false;
          TraceForge = false;
          TraceHandshake = false;
          TraceInboundGovernor = false;
          TraceIpSubscription = false;
          TraceLedgerPeers = false;
          TraceLocalConnectionManager = false;
          TraceLocalErrorPolicy = false;
          TraceLocalHandshake = false;
          TraceLocalRootPeers = false;
          TraceMempool = false;
          TracePeerSelectionActions = false;
          TracePeerSelectionCounters = false;
          TracePeerSelection = false;
          TracePublicRootPeers = false;
          TraceServer = false;
        };
      };
      #
      # disableP2p = {
      #   services.cardano-node = {
      #     useNewTopology = false;
      #     extraNodeConfig.EnableP2P = false;
      #   };
      # };
      #
      # Allow legacy group incoming connections on bps if non-p2p testing is required:
      # mkBpLegacyFwRules = nodeNameList: nixos: {
      #   networking.firewall = {
      #     extraCommands = concatMapStringsSep "\n" (n: "iptables -t filter -I nixos-fw -i ens5 -p tcp -m tcp -s ${nixos.nodes.${n}.config.ips.publicIpv4} --dport 3001 -j nixos-fw-accept") nodeNameList;
      #     extraStopCommands = concatMapStringsSep "\n" (n: "iptables -t filter -D nixos-fw -i ens5 -p tcp -m tcp -s ${nixos.nodes.${n}.config.ips.publicIpv4} --dport 3001 -j nixos-fw-accept || true") nodeNameList;
      #   };
      # };
      #
      # Example add fw rules for relay to block producer connections in non-p2p network setup;
      # private1bpLegacy = mkBpLegacyFwRules ["private1-rel-a-1" "private1-rel-a-2" "private1-rel-a-3"];
      # private2bpLegacy = mkBpLegacyFwRules ["private2-rel-b-1" "private2-rel-b-2" "private2-rel-b-3"];
      # private3bpLegacy = mkBpLegacyFwRules ["private3-rel-c-1" "private3-rel-c-2" "private3-rel-c-3"];
      #
      # # A legacy machine will need to have at least partial peer mesh to other groups:
      # extraProd = producerList: {services.cardano-node-topology.extraNodeListProducers = producerList;};
      #
      # Extra legacy producers for inter-region connectivity on a non-p2p deployment:
      # priv1extraProducers = extraProd ["private2-rel-b-1" "private2-rel-b-2" "private2-rel-b-3" "private3-rel-c-1" "private3-rel-c-2" "private3-rel-c-3"];
      # priv2extraProducers = extraProd ["private1-rel-a-1" "private1-rel-a-2" "private1-rel-a-3" "private3-rel-c-1" "private3-rel-c-2" "private3-rel-c-3"];
      # priv3extraProducers = extraProd ["private1-rel-a-1" "private1-rel-a-2" "private1-rel-a-3" "private2-rel-b-1" "private2-rel-b-2" "private2-rel-b-3"];
      #
      # privPubProducer = {
      #   services.cardano-node.producers = [
      #     {
      #       accessPoints = [
      #         {
      #           address = "private-node.play.dev.cardano.org";
      #           port = 3001;
      #           valency = 2;
      #         }
      #       ];
      #       advertise = false;
      #     }
      #   ];
      # };
      #
      # rtsOptMods = {
      #   nodeResources,
      #   lib,
      #   ...
      # }: let
      #   inherit (nodeResources) cpuCount; # memMiB;
      # in {
      #   services.cardano-node.rtsArgs = lib.mkForce [
      #     "-N${toString cpuCount}"
      #     "-A16m"
      #     "-I3"
      #     # Temporarily match the m5a-xlarge spec
      #     "-M12943.360000M"
      #     # "-M${toString (memMiB * 0.79)}M"
      #   ];
      # };
      #
      # gcLogging = {services.cardano-node.extraNodeConfig.options.mapBackends."cardano.node.resources" = ["EKGViewBK" "KatipBK"];};
      #
      # Example of node pinning to a custom version; see also the relevant flake inputs.
      # dbsync873 = {
      #   imports = [
      #     "${inputs.cardano-node-873-service}/nix/nixos/cardano-node-service.nix"
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
      #     inputs.cardano-parts.nixosModules.profile-cardano-db-sync
      #     inputs.cardano-parts.nixosModules.profile-cardano-node-group
      #     inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
      #     inputs.cardano-parts.nixosModules.profile-cardano-postgres
      #     {
      #       cardano-parts.perNode = {
      #         lib.cardanoLib = config.flake.cardano-parts.pkgs.special.cardanoLibCustom inputs.iohk-nix-873 "x86_64-linux";
      #         pkgs = {inherit (inputs.cardano-node-873.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;};
      #       };
      #       services.cardano-node.shareNodeSocket = true;
      #       services.cardano-postgres.enablePsqlrc = true;
      #     }
      #   ];
      # };
      #
      # hostsListByPrefix = prefix: {
      #   cardano-parts.perNode.meta.hostsList =
      #     filter (name: hasPrefix prefix name) (attrNames nixosConfigurations);
      # };
    in {
      meta = {
        nixpkgs = import inputs.nixpkgs {
          system = "x86_64-linux";
        };

        nodeSpecialArgs =
          foldl'
          (acc: node: let
            instanceType = node: nixosConfigurations.${node}.config.aws.instance.instance_type;
          in
            recursiveUpdate acc {
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
          {} (attrNames nixosConfigurations);
      };

      defaults.imports = [
        inputs.cardano-parts.nixosModules.module-aws-ec2
        inputs.cardano-parts.nixosModules.profile-cardano-parts
        inputs.cardano-parts.nixosModules.profile-basic
        inputs.cardano-parts.nixosModules.profile-common
        inputs.cardano-parts.nixosModules.profile-grafana-agent
        nixosModules.common
        nixosModules.ip-module-check
      ];

      # Setup cardano-world networks:
      # ---------------------------------------------------------------------------------------------------------
      # Preprod, two-thirds on release tag, one-third on pre-release tag
      preprod1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod1") node bp mithrilRelease (declMRel "preprod1-rel-a-1")];};
      preprod1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod1") node rel preprodRelMig mithrilRelay (declMSigner "preprod1-bp-a-1")];};
      preprod1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod1") node rel preprodRelMig];};
      preprod1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod1") node rel preprodRelMig];};
      preprod1-dbsync-a-1 = {imports = [eu-central-1 r5-large (ebs 100) (group "preprod1") dbsync smash preprodSmash];};
      preprod1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod1") node faucet preprodFaucet];};

      preprod2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod2") node bp mithrilRelease (declMRel "preprod2-rel-b-1")];};
      preprod2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod2") node rel preprodRelMig];};
      preprod2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod2") node rel preprodRelMig mithrilRelay (declMSigner "preprod2-bp-b-1")];};
      preprod2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod2") node rel preprodRelMig];};

      preprod3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod3") node bp pre mithrilRelease (declMRel "preprod3-rel-c-1")];};
      preprod3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod3") node rel pre preprodRelMig];};
      preprod3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod3") node rel pre preprodRelMig];};
      preprod3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "preprod3") node rel pre preprodRelMig mithrilRelay (declMSigner "preprod3-bp-c-1")];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Preview, one-third on release tag, two-thirds on pre-release tag
      preview1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview1") node bp mithrilRelease (declMRel "preview1-rel-a-1")];};
      preview1-rel-a-1 = {imports = [eu-central-1 c6i-xlarge (ebs 80) (nodeRamPct 60) (group "preview1") node rel newMetrics logRejected previewRelMig mithrilRelay (declMSigner "preview1-bp-a-1")];};
      preview1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview1") nodeTxDelay minLog rel previewRelMig];};
      preview1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview1") nodeTxDelay rel previewRelMig];};
      preview1-dbsync-a-1 = {imports = [eu-central-1 r5-large (ebs 100) (group "preview1") dbsync smash previewSmash];};
      preview1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview1") node faucet previewFaucet];};

      preview2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview2") node bp pre mithrilRelease (declMRel "preview2-rel-b-1")];};
      preview2-rel-a-1 = {imports = [eu-central-1 c6i-xlarge (ebs 80) (nodeRamPct 60) (group "preview2") node traceTxs rel pre previewRelMig];};
      preview2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview2") nodeTxDelay rel previewRelMig mithrilRelay (declMSigner "preview2-bp-b-1")];};
      preview2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview2") nodeTxDelay rel previewRelMig];};

      preview3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview3") node bp pre mithrilRelease (declMRel "preview3-rel-c-1")];};
      preview3-rel-a-1 = {imports = [eu-central-1 c6i-xlarge (ebs 80) (nodeRamPct 60) (group "preview3") node rel pre previewRelMig];};
      preview3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview3") nodeTxDelay rel previewRelMig];};
      preview3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "preview3") nodeTxDelay rel previewRelMig mithrilRelay (declMSigner "preview3-bp-c-1")];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Private, pre-release--include-all-instances
      private1-bp-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private1") node bp];};
      private1-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private1") node rel];};
      private1-rel-a-2 = {imports = [eu-central-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private1") node rel];};
      private1-rel-a-3 = {imports = [eu-central-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private1") node rel];};
      private1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "private1") dbsync nixosModules.govtool-backend {services.govtool-backend.primaryNginx = true;}];};
      private1-faucet-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private1") node faucet privateFaucet];};

      private2-bp-b-1 = {imports = [eu-west-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private2") node bp];};
      private2-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private2") node rel];};
      private2-rel-b-2 = {imports = [eu-west-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private2") node rel];};
      private2-rel-b-3 = {imports = [eu-west-1 t3a-small (ebs 80) (nodeRamPct 70) (group "private2") node rel];};

      private3-bp-c-1 = {imports = [us-east-2 t3a-small (ebs 80) (nodeRamPct 70) (group "private3") node bp];};
      private3-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 80) (nodeRamPct 70) (group "private3") node rel];};
      private3-rel-c-2 = {imports = [us-east-2 t3a-small (ebs 80) (nodeRamPct 70) (group "private3") node rel];};
      private3-rel-c-3 = {imports = [us-east-2 t3a-small (ebs 80) (nodeRamPct 70) (group "private3") node rel];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Sanchonet, pre-release
      sanchonet1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet1") node bp (declMRel "sanchonet1-rel-a-1")];};
      sanchonet1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet1") node rel sanchoRelMig mithrilRelay (declMSigner "sanchonet1-bp-a-1")];};
      sanchonet1-rel-a-2 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet1") node rel sanchoRelMig];};
      sanchonet1-rel-a-3 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet1") node rel sanchoRelMig];};
      sanchonet1-dbsync-a-1 = {imports = [eu-central-1 m5a-large (ebs 80) (group "sanchonet1") dbsync smash sanchoSmash nixosModules.govtool-backend];};
      sanchonet1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet1") node faucet sanchoFaucet];};
      sanchonet1-test-a-1 = {imports = [eu-central-1 c5ad-large (ebs 80) (nodeRamPct 60) (group "sanchonet1") node newMetrics];};

      sanchonet2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet2") node bp (declMRel "sanchonet2-rel-b-1")];};
      sanchonet2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet2") node rel sanchoRelMig mithrilRelay (declMSigner "sanchonet2-bp-b-1")];};
      sanchonet2-rel-b-2 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet2") node rel sanchoRelMig];};
      sanchonet2-rel-b-3 = {imports = [eu-west-1 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet2") node rel sanchoRelMig];};

      sanchonet3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet3") node newMetrics bp (declMRel "sanchonet3-rel-c-1")];};
      sanchonet3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet3") node rel sanchoRelMig mithrilRelay (declMSigner "sanchonet3-bp-c-1")];};
      sanchonet3-rel-c-2 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet3") node rel sanchoRelMig];};
      sanchonet3-rel-c-3 = {imports = [us-east-2 t3a-medium (ebs 80) (nodeRamPct 60) (group "sanchonet3") node newMetrics rel sanchoRelMig];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Shelley-qa, pre-release
      shelley-qa1-bp-a-1 = {imports = [eu-central-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa1") node bp];};
      shelley-qa1-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa1") node rel];};
      shelley-qa1-rel-a-2 = {imports = [eu-central-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa1") node rel];};
      shelley-qa1-rel-a-3 = {imports = [eu-central-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa1") node rel];};
      shelley-qa1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "shelley-qa1") dbsync smash shelleySmash];};
      shelley-qa1-faucet-a-1 = {imports = [eu-central-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa1") node faucet shelleyFaucet];};

      shelley-qa2-bp-b-1 = {imports = [eu-west-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa2") node bp];};
      shelley-qa2-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa2") node rel];};
      shelley-qa2-rel-b-2 = {imports = [eu-west-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa2") node rel];};
      shelley-qa2-rel-b-3 = {imports = [eu-west-1 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa2") node rel];};

      shelley-qa3-bp-c-1 = {imports = [us-east-2 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa3") node bp];};
      shelley-qa3-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa3") node rel];};
      shelley-qa3-rel-c-2 = {imports = [us-east-2 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa3") node rel];};
      shelley-qa3-rel-c-3 = {imports = [us-east-2 t3a-micro (ebs 80) (nodeRamPct 70) (group "shelley-qa3") node rel];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Mainnet
      # Rel-a-1 is set up as a fake block producer for gc latency testing during ledger snapshots
      # Rel-a-{2,3} lmdb and mdb fault tests
      # Rel-a-4 addnl current release tests
      # Dbsync-a-2 is kept in stopped state unless actively needed for testing and excluded from the machine count alert
      mainnet1-dbsync-a-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync dbsyncPub (openFwTcp 5432)];};
      mainnet1-dbsync-a-2 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync disableAlertCount];};

      # mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node nodeGhc963 (openFwTcp 3001) bp gcLogging rtsOptMods];};
      # mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node nodeGhc963 (openFwTcp 3001)];};
      # mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node (openFwTcp 3001)];};
      mainnet1-rel-a-1 = {imports = [eu-central-1 r5-xlarge (ebs 300) (group "mainnet1") node newMetrics];};

      # Also keep the lmdb and extra debug mainnet node in stopped state for now
      mainnet1-rel-a-2 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node (openFwTcp 3001) nodeHd lmdb ram8gib disableAlertCount];};
      mainnet1-rel-a-3 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node (openFwTcp 3001) nodeHd lmdb ram8gib disableAlertCount];};
      mainnet1-rel-a-4 = {imports = [eu-central-1 r5-xlarge (ebs 300) (group "mainnet1") nodeHd newMetrics];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Misc
      misc1-metadata-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "misc1") metadata nixosModules.cardano-ipfs];};
      misc1-webserver-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "misc1") webserver (varnishRamPct 50)];};
      # ---------------------------------------------------------------------------------------------------------
    };
  }
