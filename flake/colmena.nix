flake @ {
  inputs,
  config,
  lib,
  self,
  moduleWithSystem,
  withSystem,
  ...
}: let
  inherit (config.flake) nixosModules nixosConfigurations;
  inherit (config.flake.cardano-parts.cluster.infra.aws) domain;
in
  with builtins;
  with lib; {
    flake.colmena = let
      # Region defs:
      eu-central-1.aws.region = "eu-central-1"; # a
      eu-west-1.aws.region = "eu-west-1"; # b
      us-east-2.aws.region = "us-east-2"; # c
      eu-north-1.aws.region = "eu-north-1"; # d
      ap-southeast-2.aws.region = "ap-southeast-2"; # e
      sa-east-1.aws.region = "sa-east-1"; # f
      af-south-1.aws.region = "af-south-1"; # g
      ap-northeast-1.aws.region = "ap-northeast-1"; # h
      us-west-1.aws.region = "us-west-1"; # i
      us-west-2.aws.region = "us-west-2"; # j

      # Instance defs:
      # c5a-large.aws.instance.instance_type = "c5a.large";
      # c5ad-large.aws.instance.instance_type = "c5ad.large";
      c5d-xlarge.aws.instance.instance_type = "c5d.xlarge";
      c6id-large.aws.instance.instance_type = "c6id.large";
      c6id-xlarge.aws.instance.instance_type = "c6id.xlarge";
      # c6i-12xlarge.aws.instance.instance_type = "c6i.12xlarge";
      c8id-large.aws.instance.instance_type = "c8id.large";
      c8id-xlarge.aws.instance.instance_type = "c8id.xlarge";
      c8id-2xlarge.aws.instance.instance_type = "c8id.2xlarge";
      # i7ie-2xlarge.aws.instance.instance_type = "i7ie.2xlarge";
      # m5a-large.aws.instance.instance_type = "m5a.large";
      # m5ad-large.aws.instance.instance_type = "m5ad.large";
      m5ad-xlarge.aws.instance.instance_type = "m5ad.xlarge";
      m6id-xlarge.aws.instance.instance_type = "m6id.xlarge";
      m8id-xlarge.aws.instance.instance_type = "m8id.xlarge";
      # m5a-2xlarge.aws.instance.instance_type = "m5a.2xlarge";
      r5-xlarge.aws.instance.instance_type = "r5.xlarge";
      r5-2xlarge.aws.instance.instance_type = "r5.2xlarge";
      # r5d-4xlarge.aws.instance.instance_type = "r5d.4xlarge";
      r6a-large.aws.instance.instance_type = "r6a.large";
      r6a-xlarge.aws.instance.instance_type = "r6a.xlarge";
      # t3a-micro.aws.instance.instance_type = "t3a.micro";
      # t3a-small.aws.instance.instance_type = "t3a.small";
      t3-medium.aws.instance.instance_type = "t3.medium";
      t3a-medium.aws.instance.instance_type = "t3a.medium";
      t3a-large.aws.instance.instance_type = "t3a.large";
      # t3a-xlarge.aws.instance.instance_type = "t3a.xlarge";

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
        # Apply group wide common imports
        imports =
          optionals (hasPrefix "buildkite" name) [buildkite]
          ++ optionals (hasPrefix "dijkstra" name) [noBPerf amiZfs]
          ++ optionals (hasPrefix "leios" name) [amiZfs leiosLogging inputs.cardano-parts.nixosModules.profile-zfs-snapshots]
          ++ optionals (hasPrefix "preview" name) [hiConn]
          ++ optionals (hasPrefix "preprod" name) [hiConn]
          ++ optionals (hasPrefix "sanchonet" name) [noBPerf]
          ++ optionals (hasPrefix "mainnet" name) [];

        cardano-parts.cluster.group = config.flake.cardano-parts.cluster.groups.${name};

        # Since all machines are assigned a group, this is a good place to include default aws instance tags
        aws.instance.tags =
          {
            # This group environment name will override the
            # flake.cluster.infra.generic environment name for aws instances.
            environment = config.flake.cardano-parts.cluster.groups.${name}.meta.environmentName;
            group = name;
          }
          // optionalAttrs (hasPrefix "leios" name) {
            costCenter = "\${var.tag_costCenterLeios}";
          };
      };

      # Cardano-node modules for group deployment
      node = {
        imports = [
          # Base cardano-node and tracer service
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-tracer-service
          # Config for cardano-node group deployments
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
          bperfNoPublish
        ];
      };

      node-pre = {
        imports = [
          # Base cardano-node service
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service-ng
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-tracer-service-ng

          # Config for cardano-node group deployments
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
          bperfNoPublish

          pre
        ];
      };

      # Opt a leios node OUT of the 2-day recycle below.
      # nodeNoRecycle.systemd.services.cardano-node.serviceConfig = {
      #   RuntimeMaxSec = mkForce "infinity";
      #   RuntimeRandomizedExtraSec = mkForce 0;
      # };

      node-leios =
        # Ouroboros leios makes leios prototype packages available through its cardano-node-leios input
        mkCustomNodePre "cardano-node-leios.inputs.cardano-node-leios"
        // {
          services.cardano-node.extraNodeConfig = {
            ConsensusMode = "PraosMode";

            LeiosDbConfig = {
              Backend = "SQLite";
              # Ideally we probably want this saved in the chainDB state dir.
              # Relative dirs to the process cwd should also work.
              # Filepath = "db-leios/leios.db";
              Filepath = "/ephemeral/cardano-node/leios.db";
            };

            # Additional cfg to debug network issues
            TraceOptions = {
              "BlockFetch.Client".severity = "Info";
              "BlockFetch.Decision" = {
                severity = "Debug";
                maxFrequency = 2.0;
              };
              "ChainSync.Client".severity = "Debug";
              "ChainSync.ServerHeader" = {
                severity = "Info";
                maxFrequency = 2.0;
              };
              "ChainDB.AddBlockEvent".severity = "Debug";
              "ChainDB.AddBlockEvent.PoppedBlockFromQueue".maxFrequency = 2.0;
              "ChainDB.AddBlockEvent.AddBlockValidation".severity = "Info";
            };
          };

          # Temporary mitigation for the under-investigation leios cardano-node
          # heap leak (root-caused to unpruned LeiosVoteState growth; exhausts
          # host RAM in ~3 days): recycle the service every ~2 days so memory
          # can't grow unbounded. RuntimeMaxSec caps runtime;
          # RuntimeRandomizedExtraSec adds 0..N jitter so the fleet doesn't
          # restart in lockstep (thundering herd). Window 44-48h (<= 2 days).
          # Restart=always (cardano-parts) brings the node back; TimeoutStopSec=600
          # leaves room for a clean shutdown. Analysis/observer nodes opt out via
          # nodeNoRecycle. Remove once the leak is fixed.
          systemd.services.cardano-node.serviceConfig = {
            RuntimeMaxSec = 44 * 3600;
            RuntimeRandomizedExtraSec = 4 * 3600;
          };
        };

      # Same as node-leios, but the cardano-node binary is rebuilt with
      # info-table-provenance (IPE) flags for low-overhead `+RTS -hi` profiling.
      # node-leios-ipe = {
      #   imports = [
      #     node-leios
      #     nodeNoRecycle # profiling build: let the heap grow for leak analysis
      #     {
      #       cardano-parts.perNode.pkgs.cardano-node = lib.mkOverride 40 (
      #         (inputs.cardano-node-leios.inputs.cardano-node-leios.project.x86_64-linux.appendModule {
      #           modules = [{
      #             ghcOptions = ["-finfo-table-map" "-fdistinct-constructor-tables"];
      #             packages.plutus-core.components.library.ghcOptions = ["-finfo-table-map" "-fdistinct-constructor-tables"];
      #           }];
      #         }).exes.cardano-node
      #       );
      #     }
      #   ];
      # };

      # Same as node-leios-ipe, but the node is ALSO built with the ghc-debug
      # stub, so its live heap can be snapshotted on demand for offline retainer
      # analysis (to find what retains the growing ARR_WORDS / STACK closures the
      # -hi profile can only name, not attribute).
      #
      # `+RTS -hi` heap profiling comes along for free and is enabled below:
      # one node run yields BOTH the continuous -hi eventlog and on-demand
      # ghc-debug snapshots.
      # node-leios-ghc-debug = {
      #   imports = [
      #     node-leios
      #     nodeNoRecycle # ghc-debug build: let the heap grow for leak analysis
      #     {
      #       cardano-parts.perNode.pkgs.cardano-node =
      #         lib.mkOverride 40
      #         inputs.cardano-node-leios-ghc-debug.inputs.cardano-node-leios.packages.x86_64-linux.cardano-node-debug;

      #       # The ghc-debug stub serves here; the snapshot client reads the same
      #       # path. /run/cardano-node is the node's RuntimeDirectory -- writable
      #       # by the cardano-node user and ephemeral across restarts.
      #       systemd.services.cardano-node.environment.GHC_DEBUG_SOCKET = "/run/cardano-node/ghc-debug.socket";

      #       # IPE "free extra": continuous low-overhead info-table (-hi) heap
      #       # profile written to the eventlog (`eventlog` -> -l, `space-info` ->
      #       # -hi). `-i30` keeps the heap census cheap on a large heap; the 0.1s
      #       # default would be far too aggressive. rts_flags_override appends, so
      #       # the compiled-in -N2/-A16m/etc. are preserved.
      #       #
      #       # `-l-agu` trims the eventlog to what eventlog2html needs: it comes
      #       # after the service's `-l`, and its class mods apply cumulatively --
      #       # `-a` disables every event class, then `g`/`u` re-enable GC/heap
      #       # and user events (heap-profile samples + IPE map still included).
      #       # Without it, scheduler events dominate and a multi-day -hi run
      #       # produces a multi-GB eventlog (6.4GB in 14h observed).
      #       #
      #       # The flush interval forces buffered events to disk periodically:
      #       # eventlog writes sit in ~2MB per-capability buffers that only
      #       # flush when full, and with the slim -l-agu classes that can take
      #       # tens of minutes -- without it the on-disk log lags far behind and
      #       # a mid-run copy is missing the newest samples.
      #       services.cardano-node = {
      #         eventlog = true;
      #         profiling = "space-info";
      #         rts_flags_override = ["-i30" "-l-agu" "--eventlog-flush-interval=300"];
      #       };

      #       # Headless snapshot client on the host PATH. Capture EARLY (moderate
      #       # heap), NOT at the OOM ceiling -- a snapshot is ~heap-sized and
      #       # pauses the node for its duration:
      #       #   cardano-ghc-debug-snapshot \
      #       #     heap.snapshot \
      #       #     "$GHC_DEBUG_SOCKET"
      #       environment.systemPackages = [
      #         inputs.cardano-node-leios-ghc-debug.inputs.cardano-node-leios.packages.x86_64-linux.cardano-debug
      #       ];
      #     }
      #   ];
      # };

      eRel = relList: {
        imports = [
          inputs.cardano-parts.nixosModules.profile-cardano-node-topology
          {
            services.cardano-node-topology = {
              role = mkDefault "edge";
              extraNodeListProducers =
                map (name: {
                  inherit name;
                  trustable = true;
                  addressType = "fqdn";
                })
                relList;
            };
          }
        ];
      };

      leiosBp = {
        imports = [
          bp
          {
            services.cardano-node.extraNodeConfig = {
              # Enable the Forge.Loop.Call call-trace spans (kind="Call",
              # sev=Debug) that feed the leios call-trace Grafana dashboard.
              # Only forgers run the forge loop, so this lives on the BPs only;
              # parent Forge.Loop stays at Info (base config), and this
              # more-specific child override turns on just the call-trace.
              TraceOptions."Forge.Loop.Call".severity = "Debug";
            };
          }
        ];
      };

      leiosRedTeamBp = {
        config,
        pkgs,
        ...
      }: let
        inherit (config.cardano-parts.perNode.meta) cardanoNodePort;
        inherit (config.cardano-parts.perNode.lib) cardanoLib;
        inherit (config.cardano-parts.cluster) group;
        environment = cardanoLib.environments.${group.meta.environmentName};
        opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;
      in {
        imports = [
          leiosBp

          topoEdge
          # Just importing topoEdge leads to a conflict due to topoBp being imported by leiosBp.
          {services.cardano-node-topology.role = mkForce "edge";}

          nixosModules.leios-piranha
        ];

        cardano-parts.perNode.meta.enableDns = mkForce true;

        sops.secrets = opsLib.mkSopsSecret rec {
          groupOutPath = group.groupFlake.self.outPath;
          inherit (group) groupName;
          inherit name;
          pathPrefix = "${groupOutPath}/secrets/";
          secretName = "nix-access-tokens";
          keyName = "nix-access-tokens.conf";
          fileOwner = "root";
          fileGroup = "root";
        };

        nix.extraOptions = ''
          !include ${config.sops.secrets.nix-access-tokens.path}
        '';

        security.acme = {
          acceptTerms = true;
          defaults.email = "devops@iohk.io";
        };

        networking.firewall.allowedTCPPorts = [
          cardanoNodePort
          config.services.nginx.defaultHTTPListenPort
          config.services.nginx.defaultSSLListenPort
        ];

        services = {
          cardano-node = {
            useLedgerAfterSlot = mkForce environment.useLedgerAfterSlot;
            extraNodeConfig.PeerSharing = true;
          };

          cardano-leios-piranha = {
            enable = true;
            openFirewall = true;
            netClusterIp4 = "157.180.99.170";
          };
        };
      };

      leiosRel = {imports = [rel];};

      leiosCentrifuge.imports = [
        # nodeNoRecycle
        nixosModules.cardano-tx-centrifuge
        nixosModules.profile-leios-tx-centrifuge
        {
          services = {
            cardano-tx-centrifuge.settings = {
              rate_limit.params.tps = 25;
              # observers.local-follower.params.confirmation_depth = 3;
              workloads.synthetic-chain.targets.leios1-rel-a-1 = {
                addr = "leios1-rel-a-1.play.dev.cardano.org";
                port = 3001;
              };
            };
          };
        }
        (eRel ["leios1-rel-a-1" "leios2-rel-b-1" "leios3-rel-c-1"])
      ];

      leiosFilesNginx.imports = [
        nixosModules.leios-files-nginx
        {services.leios-files-nginx.acmeEmail = "devops@iohk.io";}
      ];

      # mkCustomNode = flakeInput: let
      #   input = getAttrFromPath (splitString "." flakeInput) inputs;
      # in {
      #   imports = [
      #     node
      #     {
      #       cardano-parts.perNode = {
      #         pkgs = {
      #           cardano-cli = mkForce input.packages.x86_64-linux.cardano-cli;
      #           cardano-node = mkForce input.packages.x86_64-linux.cardano-node;
      #           cardano-submit-api = mkForce input.packages.x86_64-linux.cardano-submit-api;
      #         };
      #       };
      #     }
      #   ];
      # };

      mkCustomNodePre = flakeInput: let
        input = getAttrFromPath (splitString "." flakeInput) inputs;
      in {
        imports = [
          node-pre
          {
            cardano-parts.perNode = {
              pkgs = {
                cardano-cli = mkForce input.packages.x86_64-linux.cardano-cli;
                cardano-node = mkForce input.packages.x86_64-linux.cardano-node;
                cardano-submit-api = mkForce input.packages.x86_64-linux.cardano-submit-api;
                cardano-tracer = mkForce input.packages.x86_64-linux.cardano-tracer;
              };
            };
          }
        ];
      };

      # Once node 11.1 is released this imports content can be uncommented and utilized.
      submit-api = {
        imports = [
          # The service module config default is cardanoLib submitApiConfig, so
          # no explicit config override is required here.
          # config.flake.cardano-parts.cluster.groups.default.meta.cardano-submit-api-service-ng
          # inputs.cardano-parts.nixosModules.profile-cardano-submit-api
        ];
      };

      ccMon = {imports = [inputs.cardano-parts.nixosModules.profile-cardano-committee-monitor];};

      # Include blockPerf by default with no upstream push to CF -- only push prom metrics
      bperfNoPublish = {
        imports = [
          inputs.cardano-parts.nixosModules.profile-blockperf
          {
            services.blockperf = {
              publish = false;
              useSopsSecrets = false;
            };
          }
        ];
      };

      # Mithril signing config
      mithrilRelay = {imports = [inputs.cardano-parts.nixosModules.profile-mithril-relay];};
      declMRel = node: {services.mithril-signer.relayEndpoint = nixosConfigurations.${node}.config.ips.privateIpv4 or "ip-module not available";};
      declMSigner = node: {services.mithril-relay.signerIp = nixosConfigurations.${node}.config.ips.privateIpv4 or "ip-module not available";};

      # Profiles
      pre = {imports = [inputs.cardano-parts.nixosModules.profile-pre-release];};

      openFwTcp = port: {networking.firewall.allowedTCPPorts = [port];};

      nodeRamPct = ramPercent: nixos: {services.cardano-node.totalMaxHeapSizeMiB = nixos.nodeResources.memMiB * ramPercent / 100;};

      # Historically, this parameter could result in up to 4 times the specified amount of ram being consumed.
      # However, this doesn't seem to be the case anymore.
      varnishRamPct = ramPercent: nixos: {services.cardano-webserver.varnishRamAvailableMiB = nixos.nodeResources.memMiB * ramPercent / 100;};

      ram8gib = nixos: {
        # On an 8 GiB machine, 7.5 GiB is reported as available in free -h; 74%
        services.cardano-node.totalMaxHeapSizeMiB = 5734;
        systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "7G";
      };

      # ram4gib = nixos: {
      #   # On an 4 GiB machine, 3.5 GiB is reported as available in free -h; 74%
      #   services.cardano-node.totalMaxHeapSizeMiB = 2652;
      #   systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "3G";
      # };

      lsm = {
        services.cardano-node = {
          lsmDatabasePath = "/ephemeral/cardano-node/";
          withUtxoHdLsmt = true;
        };
      };

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
      topoEdge = {imports = [inputs.cardano-parts.nixosModules.profile-cardano-node-topology {services.cardano-node-topology = {role = "edge";};}];};

      # The new default snapshot interval that will be used starting with node 11.1.0 is 40 * k.
      # This snippet sets the same thing on node 11.0.1.
      "snap40k" = {
        imports = [
          (nixos: let
            inherit (nixos.config.cardano-parts.cluster.group.meta) environmentName;
            inherit (nixos.config.cardano-parts.perNode.lib) cardanoLib;
            inherit (cardanoLib.environments.${environmentName}.nodeConfig) ShelleyGenesisFile;
            k = (fromJSON (readFile ShelleyGenesisFile)).securityParam;
          in {
            services.cardano-node.extraNodeConfig.LedgerDB.SnapshotInterval = 40 * k;
          })
        ];
      };

      # Roles
      bp = {
        imports = [
          inputs.cardano-parts.nixosModules.role-block-producer
          topoBp
          {
            # Disable machine DNS creation for block producers to avoid ip discovery
            cardano-parts.perNode.meta.enableDns = false;
          }
        ];
      };

      rel = {imports = [inputs.cardano-parts.nixosModules.role-relay topoRel];};

      dbsync = {
        imports = [
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-tracer-service
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
          inputs.cardano-parts.nixosModules.profile-cardano-db-sync
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
          inputs.cardano-parts.nixosModules.profile-cardano-postgres
          {
            services.cardano-node.shareNodeSocket = true;
            services.cardano-postgres.enablePsqlrc = true;
          }
          bperfNoPublish
        ];
      };

      # dbsync-pre = {
      #   imports = [
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service-ng
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-tracer-service-ng
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service-ng
      #     inputs.cardano-parts.nixosModules.profile-cardano-db-sync
      #     inputs.cardano-parts.nixosModules.profile-cardano-node-group
      #     inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
      #     inputs.cardano-parts.nixosModules.profile-cardano-postgres
      #     {
      #       # cardano-parts.perNode = {
      #       #   lib.cardanoLib = config.flake.cardano-parts.pkgs.special.cardanoLibCustom inputs.iohk-nix-custom "x86_64-linux";
      #       #   pkgs = {inherit (inputs.cardano-node-custom.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;};
      #       # };
      #       services.cardano-node.shareNodeSocket = true;
      #       services.cardano-postgres.enablePsqlrc = true;
      #     }

      #     pre
      #     bperfNoPublish
      #   ];
      # };

      dbsync-leios = {
        imports = [
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
          inputs.cardano-parts.nixosModules.profile-cardano-db-sync
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
          inputs.cardano-parts.nixosModules.profile-cardano-postgres
          (nixos: {
            services.cardano-node.shareNodeSocket = true;
            services.cardano-postgres.enablePsqlrc = true;

            cardano-parts.perNode = {
              pkgs = {
                inherit (inputs.cardano-node-leios.inputs.cardano-node-leios.packages.x86_64-linux) cardano-cli cardano-node;
                cardano-db-sync = mkForce inputs.cardano-db-sync-leios.packages.x86_64-linux."cardano-db-sync:exe:cardano-db-sync";
                cardano-db-tool = mkForce inputs.cardano-db-sync-leios.packages.x86_64-linux."cardano-db-tool:exe:cardano-db-tool";
                cardano-db-sync-pkgs = mkForce {
                  inherit (nixos.config.cardano-parts.perNode.lib) cardanoLib;
                  cardanoDbSyncHaskellPackages.cardano-db-tool.components.exes.cardano-db-tool = nixos.config.cardano-parts.perNode.pkgs.cardano-db-tool;
                  # This pin remains the same and doesn't need to be updated
                  schema = "${inputs.cardano-db-sync-leios}/schema";
                };
              };
            };
          })
          (eRel ["leios1-rel-a-1" "leios2-rel-b-1" "leios3-rel-c-1"])
        ];
      };

      # ogmios = {
      #   imports = [
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-ogmios-service
      #     nixosModules.ogmios
      #   ];
      # };

      # pparamsApi = {
      #   imports = [
      #     nixosModules.profile-cardano-node-pparams-api
      #     {
      #       services = {
      #         cardano-node.shareNodeSocket = true;
      #         cardano-node-pparams-api = {
      #           acmeEmail = "devops@iohk.io";
      #         };
      #       };
      #     }
      #   ];
      # };

      mithrilRelease = {imports = [nixosModules.mithril-release-pin];};
      mithrilSignerDisable = {services.mithril-signer.enable = false;};

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
          #   create user <USER> login password '<PASSWORD>';
          #   grant pg_read_all_data to <USER>;
          #
          # Access:
          # psql "host=$HOST port=$PORT user=$USER dbname=$DB sslmode=require"
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

      dijkstraSmash = {services.cardano-smash.serverAliases = ["dijkstra-smash.${domain}"];};
      mainnetSmash = {services.cardano-smash.serverAliases = ["mainnet-smash.${domain}"];};
      mainnet2Smash = {services.cardano-smash.serverAliases = ["mainnet2-smash.${domain}"];};
      preprodSmash = {services.cardano-smash.serverAliases = flatten (map (e: ["${e}.${domain}" "${e}.world.dev.cardano.org"]) ["preprod-smash" "preprod-explorer"]);};
      previewSmash = {services.cardano-smash.serverAliases = flatten (map (e: ["${e}.${domain}" "${e}.world.dev.cardano.org"]) ["preview-smash" "preview-explorer"]);};
      sanchonetSmash = {services.cardano-smash.serverAliases = ["sanchonet-smash.${domain}"];};

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
      dijkstraFaucet = {services.cardano-faucet.serverAliases = ["faucet.dijkstra.${domain}"];};
      leiosFaucet = moduleWithSystem ({system}: _: {
        imports = [
          {
            cardano-parts.perNode.pkgs.cardano-faucet = withSystem system ({config, ...}: mkForce config.cardano-parts.pkgs.cardano-faucet-ng);
            services.cardano-faucet.serverAliases = ["faucet.leios.${domain}"];
          }
          (eRel ["leios1-rel-a-1" "leios2-rel-b-1" "leios3-rel-c-1"])
        ];
      });

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

      # Deprecated ~2 years ago -- remove in the near future.  Book configs
      # have not have port 30000 for a long time.  Consumers should use port 3001.
      preprodRelMig = mkWorldRelayMig 30000;

      # Optimize tcp sysctl and route params for long distance transmission.
      # Apply to one relay per pool group.
      # Ref: https://forum.cardano.org/t/problem-with-increasing-blocksize-or-processing-requirements/140044
      tcpTxOpt = {pkgs, ...}: {
        boot.kernel.sysctl."net.ipv4.tcp_slow_start_after_idle" = 0;

        systemd.services.tcp-tx-opt = {
          after = ["network-online.target"];
          wants = ["network-online.target"];
          wantedBy = ["multi-user.target"];

          path = with pkgs; [gnugrep iproute2];
          script = ''
            set -euo pipefail

            APPEND_OPTS="initcwnd 42 initrwnd 42"

            echo "Evalulating -4 default route options..."
            DEFAULT_ROUTE=""
            while [ "$DEFAULT_ROUTE" = "" ]; do
              echo "Waiting for the -4 default route to populate..."
              sleep 2
              DEFAULT_ROUTE=$(ip route list default)
            done

            CHANGE_ROUTE() {
              PROT="$1"
              DEFAULT_ROUTE="$2"

              echo "Current default $PROT route is: $DEFAULT_ROUTE"

              if ! grep -q initcwnd <<< "$DEFAULT_ROUTE"; then
                echo "Adding tcp window size options to the $PROT default route..."
                eval ip "$PROT" route change "$DEFAULT_ROUTE" "$APPEND_OPTS"
              else
                echo "The $PROT default route already contains an initcwnd customization, skipping."
              fi
            }

            CHANGE_ROUTE "-4" "$DEFAULT_ROUTE"

            # Default ipv6 route output may look like:
            #   default via fe80::8c2:6ff:feb3:c2d dev ens5 proto ra metric 1002 expires 1795sec pref medium
            #
            # The `1795sec` arg will not be accepted in a route change
            # statement so must be filtered.
            DEFAULT_ROUTE=$(ip -6 route list default | sed 's/ expires [0-9]\+sec//')
            if [ "$DEFAULT_ROUTE" = "" ]; then
              echo "The -6 default route is not set, skipping."
            else
              CHANGE_ROUTE "-6" "$DEFAULT_ROUTE"
            fi
          '';

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };
      };

      # Non-default accepted connection limits for high load relays
      hiConn = {
        services.cardano-node.extraNodeConfig = {
          AcceptedConnectionsLimit = {
            # Default node process NOFILE limit is 65535
            # If machines support sufficient bandwidth and CPU, defaults can be raised

            # Following are the node defaults:
            # hardLimit = 512
            # softLimit = 384
            # delay = 5;

            hardLimit = 1024;
            softLimit = 768;
            delay = 5;
          };
        };
      };

      leiosLogging = {
        imports = [
          # Alloy pipelines deriving the leios Loki streams from the journald
          # machine-format trace lines configured below.
          nixosModules.leios-alloy-logs
          {
            services = {
              cardano-node.extraNodeConfig = {
                TraceOptions = {
                  "" = {
                    backends = [
                      "EKGBackend"
                      "Forwarder"
                      "PrometheusSimple suffix 127.0.0.1 12798"
                      "Stdout MachineFormat"
                    ];
                    detail = "DNormal";
                    severity = "Notice";
                  };

                  "LeiosNotify.Remote" = {
                    severity = "Debug";
                    maxFrequency = 0;
                  };

                  "LeiosFetch.Remote" = {
                    severity = "Debug";
                    maxFrequency = 0;
                  };

                  "Consensus.LeiosKernel" = {
                    severity = "Debug";
                    maxFrequency = 0;
                  };

                  "Consensus.LeiosPeer" = {
                    severity = "Debug";
                    maxFrequency = 0;
                  };
                };
              };
            };
          }
        ];
      };

      # leiosMinLogging = {
      #   imports = [
      #     (nixos: {
      #       services = {
      #         cardano-node.extraNodeInstanceConfig = _: {
      #           TraceOptions = {
      #             "" = {
      #               backends = [
      #                 "EKGBackend"
      #                 "PrometheusSimple suffix 127.0.0.1 12798"
      #                 "Stdout MachineFormat"
      #               ];
      #               detail = "DNormal";
      #               severity = "Notice";
      #             };

      #             "BlockFetch.Decision".severity = "Notice";
      #             "ChainDB.AddBlockEvent".severity = "Notice";
      #             "ChainSync.Client".severity = "Notice";
      #             "Consensus.LeiosKernel".severity = "Silence";
      #             "Consensus.LeiosPeer".severity = "Silence";
      #             "LeiosFetch.Remote".severity = "Silence";
      #             "LeiosNotify.Remote".severity = "Silence";
      #             "Mempool".severity = "Silence";
      #           };
      #         };

      #         cardano-tracer.enable = false;
      #       };
      #     })
      #   ];
      # };

      buildkite = {imports = [nixosModules.buildkite-agent-containers];};

      bkCfg = queue: count: {
        lib,
        config,
        ...
      }: let
        cfg = config.services.buildkite-containers;
        hostIdSuffix = "1";
        bkTags =
          {
            system = "x86_64-linux";
          }
          // {inherit queue;};
      in {
        # We don't need to purge 10 MB daily from the nix store by default.
        nix.gc.automatic = lib.mkForce false;

        services.auto-gc = {
          # Apply some auto and hourly gc thresholds
          nixAutoMaxFreedGB = 150;
          nixAutoMinFreeGB = 90;
          nixHourlyMaxFreedGB = 600;
          nixHourlyMinFreeGB = 150;

          # The auto and hourly gc should negate the need for a weekly full gc.
          nixWeeklyGcFull = false;
        };

        services.buildkite-containers = {
          inherit hostIdSuffix;

          # There should be enough space on these machines to cache dir purges.
          weeklyCachePurge = false;

          containerList = let
            mkContainer = n: prio: {
              containerName = "ci${cfg.hostIdSuffix}-${toString n}";
              guestIp = "10.254.1.1${toString n}";
              inherit prio;
              tags = bkTags;
            };
          in
            map (n: mkContainer n (toString (10 - n))) (lib.range 1 count);
        };
      };

      amiZfs = {imports = [nixosModules.ami];};
      legacyT = {services.cardano-node.useLegacyTracing = true;};
      noBPerf = {services.blockperf.enable = false;};

      # deployIpv4 = {name, ...}: {deployment.targetHost = "${name}.ipv4";};
      #
      # hostsListByPrefix = prefix: {
      #   cardano-parts.perNode.meta.hostsList =
      #     filter (name: hasPrefix prefix name) (attrNames nixosConfigurations);
      # };

      logGc = {
        services = {
          cardano-node.extraNodeConfig = {
            TraceOptions = {
              "Resources" = {
                severity = "Debug";
                detail = "DDetailed";
                maxFrequency = 1;
              };
            };
          };
        };
      };

      # Mempool tracing for nodes whose environment silences it by default (the
      # mainnet env config ships Mempool = "Silence"; preview/preprod default to
      # "Info"). New tracing ignores the legacy `TraceMempool` key, so set the
      # namespace severity directly. Emits per-tx events (AddedTx/RemoveTxs/
      # RejectedTx); the high-frequency sub-namespaces stay silenced. For rejection
      # reasons at full detail, bump to severity = "Debug", detail = "DDetailed".
      traceMp = {
        # RejectedTx at DDetailed captures the rejection reason (ApplyTxErr), not just the txid.
        services.cardano-node.extraNodeConfig.TraceOptions = {
          "Mempool".severity = "Info";
          "Mempool.RejectedTx".detail = "DDetailed";
          "Mempool.AttemptAdd".severity = "Silence";
          "Mempool.SyncNotNeeded".severity = "Silence";
        };
      };

      # logRejected = {
      #   services = {
      #     cardano-node.extraNodeConfig = {
      #       TraceOptionResourceFrequency = 60000;
      #       TraceOptions = {
      #         "Mempool" = {
      #           severity = "Debug";
      #           detail = "DDetailed";
      #         };
      #         "Mempool.AttemptAdd" = {
      #           severity = "Debug";
      #           detail = "DDetailed";
      #         };
      #         "Mempool.SyncNotNeeded" = {
      #           severity = "Debug";
      #           detail = "DDetailed";
      #         };
      #         "TxSubmission.TxInbound" = {
      #           severity = "Debug";
      #           detail = "DDetailed";
      #         };
      #         "TxSubmission.TxOutbound" = {
      #           severity = "Debug";
      #           detail = "DDetailed";
      #         };
      #         Resources.severity = "Debug";
      #       };
      #     };
      #   };
      # };
      #
      # logSimple = nixos: {
      #   services.cardano-node.nodeConfig = let
      #     inherit (nixos.config.cardano-parts.perNode.lib) cardanoLib;
      #     inherit (nixos.config.cardano-parts.cluster.group.meta) environmentName;
      #   in
      #     mkOverride 40 (cardanoLib.environments.${environmentName}.nodeConfig
      #       // {
      #         TraceOptions = {
      #           "" = {
      #             backends = [
      #               "EKGBackend"
      #               "Forwarder"
      #               "PrometheusSimple suffix 127.0.0.1 12798"
      #               "Stdout HumanFormatColoured"
      #             ];
      #
      #             # Each tracer can specify the level of details for printing messages.
      #             # Options include `DMinimal`, `DNormal`, `DDetailed`, and `DMaximum`. If
      #             # no implementation is given, `DNormal` is chosen.
      #             detail = "DNormal";
      #
      #             # The severity levels, ranging from the least severe (`Debug`) to the
      #             # most severe (`Emergency`), provide a framework for ignoring messages
      #             # with severity levels below a globally configured severity cutoff.
      #             #
      #             # The full list of severities are:
      #             # `Debug`, `Info`, `Notice`, `Warning`, `Error`, `Critical`, `Alert` and
      #             # `Emergency`.
      #             #
      #             # To enhance severity filtering, there is also the option of `Silence`
      #             # which allows for the unconditional silencing of a specific trace,
      #             # essentially representing the deactivation of tracers -- a semantic
      #             # continuation of the functionality in the legacy system.
      #             severity = "Info";
      #           };
      #         };
      #       });
      # };
      #
      # maxVerbosity = nixos: {
      #   services.cardano-node.nodeConfig = let
      #     inherit (nixos.config.cardano-parts.cluster.group.meta) environmentName;
      #     nodeCfg = nixos.config.cardano-parts.perNode.lib.cardanoLib.environments.${environmentName}.nodeConfig;
      #   in mkOverride 10 (nodeCfg // {
      #     TraceOptions = {
      #       "" = {
      #         backends = [
      #           "EKGBackend"
      #           "Forwarder"
      #           "PrometheusSimple suffix 127.0.0.1 12798"
      #           "Stdout HumanFormatColoured"
      #         ];
      #         detail = "DDetailed";
      #         severity = "Debug";
      #       };
      #     };
      #   });
      # };
      #
      # maxVerbosityLegacy = {services.cardano-node.extraNodeConfig.TracingVerbosity = "MaximalVerbosity";};
      #
      # praosMode = {
      #   services.cardano-node = {
      #     extraNodeConfig.ConsensusMode = "PraosMode";

      #     # Useful when the peer-snapshot version is being upgraded
      #     # peerSnapshotFile = null;
      #     # useLedgerAfterSlot = -1;
      #   };
      # };

      sanchoPeers = {
        services.cardano-node-topology.extraProducers = [
          {
            address = "sancho-testnet.able-pool.io";
            port = 6002;
            # Keep explicitly non-trustable and no advertise
            trustable = true;
            advertise = false;
          }
        ];
      };
      #
      # profiled = {
      #   services.cardano-node = {
      #     rts_flags_override = ["-l" "-hi"];
      #   };
      # };
      #
      # Tig Reminders:
      #
      # Dbsync only pre-release, not any other pre-release components that `pre` module would add:
      #   tig -Sdbsync-pre-only
      #
    in {
      meta = {
        nixpkgs = import inputs.nixpkgs {
          system = "x86_64-linux";
        };

        nodeSpecialArgs =
          foldl'
          (acc: node: let
            instanceType = node: nixosConfigurations.${node}.config.aws.instance.instance_type;
            # Handle when cardano-parts isn't fully initialized (new machines)
            hasCardanoParts = config.flake ? cardano-parts && config.flake.cardano-parts ? aws;
          in
            recursiveUpdate acc (
              optionalAttrs hasCardanoParts {
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
              }
            ))
          {} (attrNames nixosConfigurations);
      };

      defaults.imports = [
        inputs.cardano-parts.nixosModules.module-aws-ec2
        inputs.cardano-parts.nixosModules.profile-aws-ec2-ephemeral
        inputs.cardano-parts.nixosModules.profile-cardano-parts
        inputs.cardano-parts.nixosModules.profile-basic
        inputs.cardano-parts.nixosModules.profile-common
        inputs.cardano-parts.nixosModules.profile-grafana-alloy
        nixosModules.common
        nixosModules.ip-module-check
      ];

      # Setup cardano-world networks:
      # ---------------------------------------------------------------------------------------------------------
      # Preprod, two-thirds on release tag, one-third on pre-release tag
      preprod1-bp-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node bp mithrilRelease snap40k (declMRel "preprod1-rel-a-1") ccMon];};
      preprod1-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node rel preprodRelMig mithrilRelay (declMSigner "preprod1-bp-a-1")];};
      preprod1-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node rel preprodRelMig];};
      preprod1-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node rel preprodRelMig tcpTxOpt];};
      preprod1-dbsync-a-1 = {imports = [eu-central-1 r6a-xlarge (ebs 200) (group "preprod1") dbsync smash preprodSmash];};
      preprod1-faucet-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node faucet preprodFaucet];};

      preprod2-bp-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod2") node bp legacyT snap40k mithrilRelease (declMRel "preprod2-rel-b-1")];};
      preprod2-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod2") node rel legacyT preprodRelMig];};
      preprod2-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod2") node rel preprodRelMig mithrilRelay (declMSigner "preprod2-bp-b-1")];};
      preprod2-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod2") node rel preprodRelMig tcpTxOpt];};

      preprod3-bp-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod3") node-pre bp traceMp mithrilRelease (declMRel "preprod3-rel-c-1")];};
      preprod3-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod3") node-pre rel traceMp preprodRelMig];};
      preprod3-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod3") node-pre rel traceMp preprodRelMig];};
      preprod3-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod3") node-pre rel traceMp preprodRelMig mithrilRelay (declMSigner "preprod3-bp-c-1") tcpTxOpt];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Preview, one-third on release tag, two-thirds on pre-release tag
      preview1-bp-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node bp snap40k mithrilRelease (declMRel "preview1-rel-a-1") ccMon];};
      preview1-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node rel mithrilRelay (declMSigner "preview1-bp-a-1")];};
      preview1-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node rel];};
      preview1-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node rel tcpTxOpt];};
      preview1-dbsync-a-1 = {imports = [eu-central-1 r6a-large (ebs 250) (group "preview1") dbsync smash previewSmash];};
      preview1-faucet-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node faucet previewFaucet];};

      # Lsm and in-mem pre-release backend testing
      preview1-test-a-1 = {imports = [eu-central-1 m5ad-xlarge (ebs 80) (nodeRamPct 70) (group "preview1") node-pre lsm noBPerf];};
      preview1-test-a-2 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node-pre noBPerf amiZfs logGc submit-api];};
      preview1-test-a-3 = {imports = [eu-central-1 m5ad-xlarge (ebs 80) (nodeRamPct 70) (group "preview1") node-pre submit-api lsm noBPerf amiZfs];};

      preview2-bp-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview2") node-pre bp mithrilRelease (declMRel "preview2-rel-b-1") ccMon];};
      preview2-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview2") node-pre rel];};
      preview2-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview2") node-pre rel mithrilRelay (declMSigner "preview2-bp-b-1")];};
      preview2-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preview2") node-pre rel tcpTxOpt];};

      preview3-bp-c-1 = {imports = [us-east-2 m5ad-xlarge (ebs 80) (nodeRamPct 70) (group "preview3") node-pre bp lsm traceMp mithrilRelease (declMRel "preview3-rel-c-1")];};
      preview3-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview3") node-pre rel traceMp];};
      preview3-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview3") node-pre rel traceMp];};
      preview3-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preview3") node-pre rel traceMp mithrilRelay (declMSigner "preview3-bp-c-1") tcpTxOpt];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Dijkstra, all on pre-release tag
      dijkstra1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "dijkstra1") node bp snap40k ccMon];};
      dijkstra1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "dijkstra1") node rel];};
      dijkstra1-dbsync-a-1 = {imports = [eu-central-1 t3a-medium (ebs 250) (group "dijkstra1") dbsync smash dijkstraSmash];};
      dijkstra1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "dijkstra1") node faucet dijkstraFaucet];};

      dijkstra2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "dijkstra2") node bp snap40k];};
      dijkstra2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "dijkstra2") node rel];};

      dijkstra3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "dijkstra3") node-pre bp traceMp];};
      dijkstra3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "dijkstra3") node-pre rel traceMp];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Leios, all on custom leios prototype version
      # Remove `ccMon` until governance works in Dijkstra era
      # leios1-bp-a-1 = {imports = [eu-central-1 c8id-large (ebs 80) (group "leios1") node-leios leiosBp ccMon];};
      leios1-bp-a-1 = {imports = [eu-central-1 c8id-large (ebs 80) (group "leios1") node-leios leiosBp];};
      leios1-rel-a-1 = {imports = [eu-central-1 m8id-xlarge (ebs 80) (nodeRamPct 70) (group "leios1") node-leios leiosRel leiosFilesNginx (eRel ["leios2-rel-b-1" "leios3-rel-c-1"])];};
      leios1-rel-a-2 = {imports = [eu-central-1 c8id-xlarge (ebs 80) (nodeRamPct 70) (group "leios1") node-leios leiosRel (eRel ["leios2-rel-b-2" "leios3-rel-c-2"])];};
      leios1-rel-a-3 = {imports = [eu-central-1 c8id-xlarge (ebs 80) (nodeRamPct 70) (group "leios1") node-leios leiosRel (eRel ["leios2-rel-b-3" "leios3-rel-c-3"])];};
      leios1-dbsync-a-1 = {imports = [eu-central-1 c8id-2xlarge (ebs 250) (group "leios1") node-leios dbsync-leios smash dbsyncPub (openFwTcp 5432)];};
      leios1-faucet-a-1 = {imports = [eu-central-1 c8id-xlarge (ebs 80) (group "leios1") node-leios faucet leiosFaucet];};
      leios1-centrifuge-a-1 = {imports = [eu-central-1 c8id-xlarge (ebs 80) (group "leios1") node-leios leiosCentrifuge];};

      leios2-bp-b-1 = {imports = [eu-west-1 c6id-large (ebs 80) (group "leios2") node-leios leiosBp];};
      leios2-rel-b-1 = {imports = [eu-west-1 m6id-xlarge (ebs 80) (nodeRamPct 70) (group "leios2") node-leios leiosRel leiosFilesNginx (eRel ["leios1-rel-a-1" "leios3-rel-c-1"])];};
      leios2-rel-b-2 = {imports = [eu-west-1 c6id-xlarge (ebs 80) (nodeRamPct 70) (group "leios2") node-leios leiosRel (eRel ["leios1-rel-a-2" "leios3-rel-c-2"])];};
      leios2-rel-b-3 = {imports = [eu-west-1 c6id-xlarge (ebs 80) (nodeRamPct 70) (group "leios2") node-leios leiosRel (eRel ["leios1-rel-a-3" "leios3-rel-c-3"])];};

      leios3-bp-c-1 = {imports = [us-east-2 c8id-large (ebs 80) (group "leios3") node-leios leiosBp];};
      leios3-rel-c-1 = {imports = [us-east-2 m8id-xlarge (ebs 80) (nodeRamPct 70) (group "leios3") node-leios leiosRel leiosFilesNginx (eRel ["leios1-rel-a-1" "leios2-rel-b-1"])];};
      leios3-rel-c-2 = {imports = [us-east-2 c8id-xlarge (ebs 80) (nodeRamPct 70) (group "leios3") node-leios leiosRel (eRel ["leios1-rel-a-2" "leios2-rel-b-2"])];};
      leios3-rel-c-3 = {imports = [us-east-2 c8id-xlarge (ebs 80) (nodeRamPct 70) (group "leios3") node-leios leiosRel (eRel ["leios1-rel-a-3" "leios2-rel-b-3"])];};

      # Leios Red Team nodes.
      # These can remotely be switched between the normal haskell node and the red team "piranha" attacker node.
      # They don't go through a relay.
      leiosred1-bp-a-1 = {imports = [eu-central-1 c8id-xlarge (ebs 80) (group "leiosred1") node-leios leiosRedTeamBp];};
      leiosred2-bp-b-1 = {imports = [eu-west-1 c6id-xlarge (ebs 80) (group "leiosred2") node-leios leiosRedTeamBp];};
      leiosred3-bp-c-1 = {imports = [us-east-2 c8id-xlarge (ebs 80) (group "leiosred3") node-leios leiosRedTeamBp];};
      leiosred4-bp-d-1 = {imports = [eu-north-1 c8id-xlarge (ebs 80) (group "leiosred4") node-leios leiosRedTeamBp];};
      leiosred5-bp-e-1 = {imports = [ap-southeast-2 c6id-xlarge (ebs 80) (group "leiosred5") node-leios leiosRedTeamBp];};
      leiosred6-bp-f-1 = {imports = [sa-east-1 c6id-xlarge (ebs 80) (group "leiosred6") node-leios leiosRedTeamBp];};
      leiosred7-bp-g-1 = {imports = [af-south-1 c5d-xlarge (ebs 80) (group "leiosred7") node-leios leiosRedTeamBp];};
      leiosred8-bp-h-1 = {imports = [ap-northeast-1 c8id-xlarge (ebs 80) (group "leiosred8") node-leios leiosRedTeamBp];};
      leiosred9-bp-i-1 = {imports = [us-west-1 c5d-xlarge (ebs 80) (group "leiosred9") node-leios leiosRedTeamBp];};
      leiosred10-bp-j-1 = {imports = [us-west-2 c8id-xlarge (ebs 80) (group "leiosred10") node-leios leiosRedTeamBp];};
      # ---------------------------------------------------------------------------------------------------------
      #
      # ---------------------------------------------------------------------------------------------------------
      # Mainnet
      # Rel-a-1 is set up as a fake block producer for gc latency testing during ledger snapshots
      # Rel-a-{2,3} lsm and mdb fault tests
      # Rel-a-4 addnl current release tests
      # Dbsync-a-2 is kept in stopped state unless actively needed for testing and excluded from the machine count alert
      mainnet1-dbsync-a-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync smash mainnetSmash dbsyncPub (openFwTcp 5432) traceMp {services.cardano-db-sync.nodeRamAvailableMiB = 20480;}];};
      mainnet1-dbsync-a-2 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync smash mainnet2Smash traceMp];};
      mainnet1-rel-a-1 = {imports = [eu-central-1 r5-xlarge (ebs 400) (group "mainnet1") node bp snap40k mithrilSignerDisable ccMon logGc traceMp];};

      mainnet1-rel-a-2 = {imports = [eu-central-1 m5ad-xlarge (ebs 400) (group "mainnet1") node lsm ram8gib (openFwTcp 3001) traceMp];};
      mainnet1-rel-a-3 = {imports = [eu-central-1 m5ad-xlarge (ebs 400) (group "mainnet1") node lsm ram8gib (openFwTcp 3001) traceMp];};
      mainnet1-rel-a-4 = {imports = [eu-central-1 r5-xlarge (ebs 400) (group "mainnet1") node-pre logGc (openFwTcp 3001) traceMp];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Misc
      misc1-metadata-a-1 = {imports = [eu-central-1 t3a-large (ebs 80) (group "misc1") metadata nixosModules.cardano-ipfs];};
      misc1-webserver-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "misc1") webserver (varnishRamPct 50)];};
      misc1-wg-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "misc1") nixosModules.wg-r2-tunnel disableAlertCount];};
      misc1-wg-b-1 = {imports = [eu-north-1 t3-medium (ebs 80) (group "misc1") nixosModules.wg-r2-tunnel disableAlertCount];};
      misc1-matomo-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "misc1") nixosModules.matomo disableAlertCount];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Buildkite temporary machines
      # Stopped machines until the `-eu` variant can run the jobs properly
      buildkite1-af-south-1-1 = {imports = [af-south-1 r5-2xlarge (ebs 1000) (group "buildkite1") (bkCfg "core-tech-bench-af" 1) disableAlertCount];};
      buildkite1-ap-southeast-2-1 = {imports = [ap-southeast-2 r5-2xlarge (ebs 1000) (group "buildkite1") (bkCfg "core-tech-bench-ap" 1) disableAlertCount];};
      buildkite1-sa-east-1-1 = {imports = [sa-east-1 r5-2xlarge (ebs 1000) (group "buildkite1") (bkCfg "core-tech-bench-sa" 1) disableAlertCount];};

      # Temporary buildkite linux queue until migration completes -- re-use the QA tmp regional server in EU
      # buildkite1-eu-central-1-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "buildkite1") (bkCfg "core-tech-bench-eu" 1)];};
      buildkite1-eu-central-1-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "buildkite1") (bkCfg "daedalus" 3)];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Sanchonet temporary machines, for disaster recovery testing with the community
      sanchonet1-bp-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "sanchonet1") node bp];};
      sanchonet1-dbsync-a-1 = {imports = [eu-central-1 r6a-xlarge (ebs 250) (group "sanchonet1") dbsync smash sanchonetSmash ccMon];};
      sanchonet1-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "sanchonet1") node-pre rel traceMp sanchoPeers];};
      # ---------------------------------------------------------------------------------------------------------
    };

    flake.colmenaHive = inputs.cardano-parts.inputs.colmena.lib.makeHive self.outputs.colmena;
  }
