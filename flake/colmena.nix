{
  inputs,
  config,
  lib,
  self,
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
      af-south-1.aws.region = "af-south-1";
      ap-southeast-2.aws.region = "ap-southeast-2";
      eu-central-1.aws.region = "eu-central-1";
      eu-west-1.aws.region = "eu-west-1";
      sa-east-1.aws.region = "sa-east-1";
      us-east-2.aws.region = "us-east-2";

      # Instance defs:
      # c5a-large.aws.instance.instance_type = "c5a.large";
      # c5ad-large.aws.instance.instance_type = "c5ad.large";
      # c6i-xlarge.aws.instance.instance_type = "c6i.xlarge";
      # c6i-12xlarge.aws.instance.instance_type = "c6i.12xlarge";
      # i7ie-2xlarge.aws.instance.instance_type = "i7ie.2xlarge";
      # m5a-large.aws.instance.instance_type = "m5a.large";
      m5ad-large.aws.instance.instance_type = "m5ad.large";
      # m5a-2xlarge.aws.instance.instance_type = "m5a.2xlarge";
      r5-xlarge.aws.instance.instance_type = "r5.xlarge";
      r5-2xlarge.aws.instance.instance_type = "r5.2xlarge";
      r6a-large.aws.instance.instance_type = "r6a.large";
      r6a-xlarge.aws.instance.instance_type = "r6a.xlarge";
      # t3a-micro.aws.instance.instance_type = "t3a.micro";
      # t3a-small.aws.instance.instance_type = "t3a.small";
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
        cardano-parts.cluster.group = config.flake.cardano-parts.cluster.groups.${name};

        # Since all machines are assigned a group, this is a good place to include default aws instance tags
        aws.instance.tags = {
          inherit (cfgGeneric) organization tribe function repo;
          environment = config.flake.cardano-parts.cluster.groups.${name}.meta.environmentName;
          group = name;
        };
      };

      # Declare a static ipv6. This should only be used for public machines
      # where ip exposure in committed code is acceptable and a vanity address
      # is needed. Ie: don't use this for bps.
      #
      # In the case that a staticIpv6 is not declared, aws will assign one
      # automatically.
      #
      # NOTE: As of aws provider 5.66.0, switching from ipv6_address_count to
      # ipv6_addresses will force an instance replacement. If a self-declared
      # ipv6 is required but destroying and re-creating instances to change
      # ipv6 is not acceptable, then until the bug is fixed, continue using
      # auto-assignment only, manually change the ipv6 in the console ui, and
      # run tf apply to update state.
      #
      # Ref: https://github.com/hashicorp/terraform-provider-aws/issues/39433
      # staticIpv6 = ipv6: {aws.instance.ipv6 = ipv6;};

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

      # nodeFix = mkCustomNode "cardanoFix";

      # mkCustomNode = flakeInput:
      #   node
      #   // {
      #     cardano-parts.perNode = {
      #       pkgs = {
      #         cardano-cli = mkForce inputs.${flakeInput}.packages.x86_64-linux.cardano-cli;
      #         cardano-node = mkForce inputs.${flakeInput}.packages.x86_64-linux.cardano-node;
      #         cardano-submit-api = mkForce inputs.${flakeInput}.packages.x86_64-linux.cardano-submit-api;
      #       };
      #     };
      #   };

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

      lmdb = {
        services.cardano-node = {
          lmdbDatabasePath = "/ephemeral/cardano-node/";
          withUtxoHdLmdb = true;
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

      # Roles
      bp = {
        imports = [
          inputs.cardano-parts.nixosModules.role-block-producer
          topoBp
          {
            # Disable machine DNS creation for block producers to avoid ip discovery
            cardano-parts.perNode.meta.enableDns = false;

            # Reduce slots missed on cloud machines with relatively low IOPS by taking only 1 snapshot per day
            services.cardano-node.extraNodeConfig.LedgerDB.SnapshotInterval = 86400;
          }
        ];
      };
      rel = {imports = [inputs.cardano-parts.nixosModules.role-relay topoRel];};

      # dbsync = {
      #   imports = [
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-tracer-service
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
      #     inputs.cardano-parts.nixosModules.profile-cardano-db-sync
      #     inputs.cardano-parts.nixosModules.profile-cardano-node-group
      #     inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
      #     inputs.cardano-parts.nixosModules.profile-cardano-postgres
      #     {
      #       services.cardano-node.shareNodeSocket = true;
      #       services.cardano-postgres.enablePsqlrc = true;
      #     }
      #     bperfNoPublish
      #   ];
      # };

      # While new tracing PRs are WIP, the new node service is required
      dbsync-pre = {
        imports = [
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service-ng
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-tracer-service-ng
          config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
          inputs.cardano-parts.nixosModules.profile-cardano-db-sync
          inputs.cardano-parts.nixosModules.profile-cardano-node-group
          inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
          inputs.cardano-parts.nixosModules.profile-cardano-postgres
          {
            services.cardano-node.shareNodeSocket = true;
            services.cardano-postgres.enablePsqlrc = true;
          }

          pre
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

      # logRejected = {
      #   services = {
      #     cardano-node.extraNodeConfig = {
      #       TraceOptionResourceFrequency = 60000;
      #       TraceOptions = {
      #         "Mempool" = {
      #           severity = "Debug";
      #           detail = "DDetailed";
      #         };
      #         # "Mempool.MempoolAttemptAdd" = {
      #         #   severity = "Debug";
      #         #   detail = "DDetailed";
      #         # };
      #         # "Mempool.MempoolAttemptingSync" = {
      #         #   severity = "Debug";
      #         #   detail = "DDetailed";
      #         # };
      #         # "Mempool.MempoolLedgerFound" = {
      #         #   severity = "Debug";
      #         #   detail = "DDetailed";
      #         # };
      #         # "Mempool.MempoolLedgerNotFound" = {
      #         #   severity = "Debug";
      #         #   detail = "DDetailed";
      #         # };
      #         # "Mempool.MempoolSyncDone" = {
      #         #   severity = "Debug";
      #         #   detail = "DDetailed";
      #         # };
      #         # "Mempool.MempoolSyncNotNeeded" = {
      #         #   severity = "Debug";
      #         #   detail = "DDetailed";
      #         # };
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

      #     cardano-tracer.nodeDefaultTraceOptions = {
      #       severity = "Notice";
      #       detail = "DNormal";
      #       backends = [
      #         # This results in journald output for the cardano-node service,
      #         # like we would normally expect. This will, however, create
      #         # duplicate logging if the tracer service resides on the same
      #         # machine as the node service.
      #         #
      #         # In general, the "human" logging which appears in the
      #         # cardano-node service is more human legible than the
      #         # "ForHuman" node logging that appears in cardano-tracer for
      #         # the same log events.
      #         "Stdout HumanFormatColoured"
      #         # "Stdout HumanFormatUncoloured"
      #         # "Stdout MachineFormat"

      #         # Leave EKG disabled in node as tracer now generates this as well.
      #         # "EKGBackend"

      #         # Forward to tracer.
      #         "Forwarder"
      #       ];
      #     };
      #   };
      # };

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

            DEFAULT_ROUTE=$(ip -6 route list default)
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

      buildkite = {imports = [nixosModules.buildkite-agent-containers];};

      bkCfg = queue: {
        lib,
        config,
        ...
      }: let
        cfg = config.services.buildkite-containers;
        hostIdSuffix = "1";
        count = 1;
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
      # Example of node pinning to a custom version; see also the relevant flake inputs.
      # dbsync921 = {
      #   imports = [
      #     "${inputs.cardano-parts.inputs.cardano-node-service}/nix/nixos/cardano-node-service.nix"
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
      #     inputs.cardano-parts.nixosModules.profile-cardano-db-sync
      #     inputs.cardano-parts.nixosModules.profile-cardano-node-group
      #     inputs.cardano-parts.nixosModules.profile-cardano-custom-metrics
      #     inputs.cardano-parts.nixosModules.profile-cardano-postgres
      #     {
      #       cardano-parts.perNode = {
      #         # lib.cardanoLib = config.flake.cardano-parts.pkgs.special.cardanoLibCustom inputs.iohk-nix-9-2-1 "x86_64-linux";
      #         pkgs = {inherit (inputs.cardano-node-9-2-1.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;};
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

      # Legacy tracing system module code samples:
      legacyT = {services.cardano-node.useLegacyTracing = true;};
      #
      # traceTxs = {
      #   services.cardano-node.extraNodeConfig = {
      #     TraceLocalTxSubmissionProtocol = true;
      #     TraceLocalTxSubmissionServer = true;
      #     TraceTxSubmissionProtocol = true;
      #     TraceTxInbound = true;
      #     TraceTxOutbound = true;
      #   };
      # };
      #
      # maxVerbosity = {services.cardano-node.extraNodeConfig.TracingVerbosity = "MaximalVerbosity";};
      #
      # mempoolDisable = {
      #   services.cardano-node.extraNodeConfig.TraceMempool = false;
      # };
      #
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
      # minLog = {
      #   services.cardano-node.extraNodeConfig = {
      #     # Let's make sure we can at least see the blockHeight in logs and metrics
      #     TraceChainDb = true;
      #     # And then shut everything else off
      #     TraceAcceptPolicy = false;
      #     TraceConnectionManager = false;
      #     TraceDiffusionInitialization = false;
      #     TraceDNSResolver = false;
      #     TraceDNSSubscription = false;
      #     TraceErrorPolicy = false;
      #     TraceForge = false;
      #     TraceHandshake = false;
      #     TraceInboundGovernor = false;
      #     TraceIpSubscription = false;
      #     TraceLedgerPeers = false;
      #     TraceLocalConnectionManager = false;
      #     TraceLocalErrorPolicy = false;
      #     TraceLocalHandshake = false;
      #     TraceLocalRootPeers = false;
      #     TraceMempool = false;
      #     TracePeerSelectionActions = false;
      #     TracePeerSelectionCounters = false;
      #     TracePeerSelection = false;
      #     TracePublicRootPeers = false;
      #     TraceServer = false;
      #   };
      # };
      #
      # gcLogging = {services.cardano-node.extraNodeConfig.options.mapBackends."cardano.node.resources" = ["EKGViewBK" "KatipBK"];};
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
      preprod1-bp-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node bp mithrilRelease (declMRel "preprod1-rel-a-1")];};
      preprod1-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node hiConn rel preprodRelMig mithrilRelay (declMSigner "preprod1-bp-a-1")];};
      preprod1-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node hiConn rel preprodRelMig];};
      preprod1-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node hiConn rel preprodRelMig tcpTxOpt];};
      preprod1-dbsync-a-1 = {imports = [eu-central-1 r6a-xlarge (ebs 200) (group "preprod1") dbsync-pre smash preprodSmash];};
      preprod1-faucet-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod1") node faucet preprodFaucet];};

      preprod2-bp-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod2") node bp legacyT mithrilRelease (declMRel "preprod2-rel-b-1")];};
      preprod2-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod2") node hiConn rel legacyT preprodRelMig];};
      preprod2-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod2") node hiConn rel preprodRelMig mithrilRelay (declMSigner "preprod2-bp-b-1")];};
      preprod2-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod2") node hiConn rel preprodRelMig tcpTxOpt];};

      preprod3-bp-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod3") node-pre bp mithrilRelease (declMRel "preprod3-rel-c-1")];};
      preprod3-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod3") node-pre hiConn rel preprodRelMig];};
      preprod3-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod3") node-pre hiConn rel preprodRelMig];};
      preprod3-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preprod3") node-pre hiConn rel preprodRelMig mithrilRelay (declMSigner "preprod3-bp-c-1") tcpTxOpt];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Preview, one-third on release tag, two-thirds on pre-release tag
      preview1-bp-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node bp mithrilRelease (declMRel "preview1-rel-a-1")];};
      # preview1-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node rel maxVerbosity previewRelMig mithrilRelay (declMSigner "preview1-bp-a-1")];};
      preview1-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node hiConn rel previewRelMig mithrilRelay (declMSigner "preview1-bp-a-1")];};
      preview1-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node hiConn rel previewRelMig];};
      preview1-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node hiConn rel previewRelMig tcpTxOpt];};
      preview1-dbsync-a-1 = {imports = [eu-central-1 r6a-large (ebs 250) (group "preview1") dbsync-pre smash previewSmash];};
      preview1-faucet-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview1") node faucet previewFaucet];};

      # Smallest d variant for testing
      preview1-test-a-1 = {imports = [eu-central-1 m5ad-large (ebs 80) (nodeRamPct 70) (group "preview1") node-pre bp mithrilSignerDisable tcpTxOpt];};

      preview2-bp-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview2") node-pre bp legacyT mithrilRelease (declMRel "preview2-rel-b-1")];};
      preview2-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview2") node-pre hiConn rel legacyT previewRelMig];};
      preview2-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview2") node-pre hiConn rel previewRelMig mithrilRelay (declMSigner "preview2-bp-b-1")];};
      preview2-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preview2") node-pre hiConn rel previewRelMig tcpTxOpt];};

      preview3-bp-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preview3") node-pre bp mithrilRelease (declMRel "preview3-rel-c-1")];};
      preview3-rel-a-1 = {imports = [eu-central-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview3") node-pre hiConn rel previewRelMig];};
      preview3-rel-b-1 = {imports = [eu-west-1 r6a-large (ebs 80) (nodeRamPct 70) (group "preview3") node-pre hiConn rel previewRelMig];};
      preview3-rel-c-1 = {imports = [us-east-2 r6a-large (ebs 80) (nodeRamPct 70) (group "preview3") node-pre hiConn rel previewRelMig mithrilRelay (declMSigner "preview3-bp-c-1") tcpTxOpt];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Mainnet
      # Rel-a-1 is set up as a fake block producer for gc latency testing during ledger snapshots
      # Rel-a-{2,3} lmdb and mdb fault tests
      # Rel-a-4 addnl current release tests
      # Dbsync-a-2 is kept in stopped state unless actively needed for testing and excluded from the machine count alert
      mainnet1-dbsync-a-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync-pre dbsyncPub (openFwTcp 5432) {services.cardano-db-sync.nodeRamAvailableMiB = 20480;}];};
      mainnet1-dbsync-a-2 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync-pre disableAlertCount];};

      # mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node nodeGhc963 (openFwTcp 3001) bp gcLogging];};
      # mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node nodeGhc963 (openFwTcp 3001)];};
      # mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node (openFwTcp 3001)];};
      mainnet1-rel-a-1 = {imports = [eu-central-1 r5-xlarge (ebs 300) (group "mainnet1") node bp mithrilSignerDisable];};

      # Also keep the lmdb and extra debug mainnet node in stopped state for now
      mainnet1-rel-a-2 = {imports = [eu-central-1 m5ad-large (ebs 300) (group "mainnet1") node lmdb ram8gib (openFwTcp 3001)];};
      mainnet1-rel-a-3 = {imports = [eu-central-1 m5ad-large (ebs 300) (group "mainnet1") node lmdb ram8gib (openFwTcp 3001)];};
      mainnet1-rel-a-4 = {imports = [eu-central-1 r5-xlarge (ebs 300) (group "mainnet1") node legacyT (openFwTcp 3001)];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Misc
      misc1-metadata-a-1 = {imports = [eu-central-1 t3a-large (ebs 80) (group "misc1") metadata nixosModules.cardano-ipfs];};
      misc1-webserver-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "misc1") webserver (varnishRamPct 50)];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Buildkite Temporary machines
      # Stopped machines until the `-eu` variant can run the jobs properly
      buildkite1-af-south-1-1 = {imports = [af-south-1 r5-2xlarge (ebs 1000) (group "buildkite1") buildkite (bkCfg "core-tech-bench-af") disableAlertCount];};
      buildkite1-ap-southeast-2-1 = {imports = [ap-southeast-2 r5-2xlarge (ebs 1000) (group "buildkite1") buildkite (bkCfg "core-tech-bench-ap") disableAlertCount];};
      buildkite1-eu-central-1-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "buildkite1") buildkite (bkCfg "core-tech-bench-eu") disableAlertCount];};
      buildkite1-sa-east-1-1 = {imports = [sa-east-1 r5-2xlarge (ebs 1000) (group "buildkite1") buildkite (bkCfg "core-tech-bench-sa") disableAlertCount];};
      # ---------------------------------------------------------------------------------------------------------
    };

    flake.colmenaHive = inputs.cardano-parts.inputs.colmena.lib.makeHive self.outputs.colmena;
  }
