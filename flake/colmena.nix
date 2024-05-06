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
      t3a-micro.aws.instance.instance_type = "t3a.micro";
      t3a-small.aws.instance.instance_type = "t3a.small";
      t3a-medium.aws.instance.instance_type = "t3a.medium";
      m5a-large.aws.instance.instance_type = "m5a.large";
      m5a-2xlarge.aws.instance.instance_type = "m5a.2xlarge";
      r5-large.aws.instance.instance_type = "r5.large";
      # r5-xlarge.aws.instance.instance_type = "r5.xlarge";
      r5-2xlarge.aws.instance.instance_type = "r5.2xlarge";

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
        ];
      };

      # Mithril signing config
      mithrilRelay = {imports = [inputs.cardano-parts.nixosModules.profile-mithril-relay];};
      declMRel = node: {services.mithril-signer.relayEndpoint = nixosConfigurations.${node}.config.ips.privateIpv4;};
      declMSigner = node: {services.mithril-relay.signerIp = nixosConfigurations.${node}.config.ips.privateIpv4;};

      # Profiles
      pre = {imports = [inputs.cardano-parts.nixosModules.profile-pre-release];};

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

      # gcLogging = {services.cardano-node.extraNodeConfig.options.mapBackends."cardano.node.resources" = ["EKGViewBK" "KatipBK"];};

      openFwTcp = port: {networking.firewall.allowedTCPPorts = [port];};

      ram8gib = nixos: {
        # On an 8 GiB machine, 7.5 GiB is reported as available in free -h
        services.cardano-node.totalMaxHeapSizeMiB = 5734;
        systemd.services.cardano-node.serviceConfig.MemoryMax = nixos.lib.mkForce "7G";
      };

      nodeHd = {
        imports = [
          (nixos: let
            inherit (nixos.config.cardano-parts.perNode.lib.opsLib) mkCardanoLib;
          in {
            cardano-parts.perNode.lib.cardanoLib = mkCardanoLib "x86_64-linux" inputs.nixpkgs inputs.iohk-nix-legacy;
            cardano-parts.perNode.pkgs = {
              inherit (inputs.cardano-node-hd.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;
            };
            services.cardano-node.publicProducers = [
              {
                accessPoints = [
                  {
                    address = "backbone.cardano.iog.io";
                    port = 3001;
                  }
                ];
                advertise = false;
              }
            ];
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
          inputs.cardano-parts.nixosModules.profile-cardano-postgres
          {services.cardano-node.shareNodeSocket = true;}
          {services.cardano-postgres.enablePsqlrc = true;}
        ];
      };

      # Example of node pinning to a custom version; see also the relevant flake inputs.
      # dbsync873 = {
      #   imports = [
      #     "${inputs.cardano-node-873-service}/nix/nixos/cardano-node-service.nix"
      #     config.flake.cardano-parts.cluster.groups.default.meta.cardano-db-sync-service
      #     inputs.cardano-parts.nixosModules.profile-cardano-db-sync
      #     inputs.cardano-parts.nixosModules.profile-cardano-node-group
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

      faucetTmpFix = {
        systemd.services.cardano-faucet = {
          # startLimitBurst = mkForce 6;
          # startLimitIntervalSec = mkForce 3600;

          # Temporarily continue restarts indefinitely
          startLimitBurst = mkForce 0;
          startLimitIntervalSec = mkForce 0;
          serviceConfig.RestartSec = mkForce "600s";
        };
      };

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
      #
      # multiInst = {services.cardano-node.instances = 2;};
      #
      # # p2p and legacy network debugging code
      netDebug = {
        services.cardano-node = {
          # useNewTopology = false;
          extraNodeConfig = {
            TraceConnectionManagerTransitions = true;
            DebugPeerSelectionInitiatorResponder = true;
            options.mapSeverity = {
              "cardano.node.DebugPeerSelectionInitiatorResponder" = "Debug";
            };
          };
        };
      };

      # minLog = {
      #   services.cardano-node.extraNodeConfig = {
      #     TraceAcceptPolicy = false;
      #     TraceChainDb = false;
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
      #     TracePeerSelection = false;
      #     TracePublicRootPeers = false;
      #     TraceServer = false;
      #   };
      # };

      newMetrics = {
        imports = [
          (
            import
            (config.flake.cardano-parts.cluster.groups.default.meta.cardano-node-service + "/cardano-tracer-service.nix")
            # Existing tracer service requires a pkgs with commonLib defined in the cardano-node repo flake overlay.
            inputs.cardano-node-8101.legacyPackages.x86_64-linux
          )
          ({
            name,
            config,
            ...
          }: let
            inherit (config.cardano-parts.cluster.group.meta) environmentName;
            inherit (config.cardano-parts.perNode.meta) cardanoNodePrometheusExporterPort hostAddr;
            inherit (config.cardano-parts.perNode.lib) cardanoLib;
            inherit (cardanoLib.environments.${environmentName}.nodeConfig) ByronGenesisFile;
            inherit ((fromJSON (readFile ByronGenesisFile)).protocolConsts) protocolMagic;
          in {
            services.cardano-tracer = {
              enable = true;
              package = inputs.cardano-parts.packages.x86_64-linux.cardano-tracer-ng;
              executable = lib.getExe inputs.cardano-parts.packages.x86_64-linux.cardano-tracer-ng;
              acceptingSocket = "/tmp/forwarder.sock";

              # Setting these alone is not enough as the config is hardcoded to use `ForMachine` output and RTView is not included.
              # So if we want more customization, we need to generate our own full config.
              # logRoot = "/tmp/logs";
              # networkMagic = protocolMagic;

              configFile = builtins.toFile "cardano-tracer-config.json" (builtins.toJSON {
                ekgRequestFreq = 1;

                # EKG interface at https.
                hasEKG = [
                  # Preserve legacy EKG binding unless we have a reason to switch.
                  # Let's see how the updated nixos node service chooses for defaults.
                  {
                    epHost = "127.0.0.1";
                    epPort = 12788;
                  }
                  {
                    epHost = "127.0.0.1";
                    epPort = 12789;
                  }
                ];

                # Metrics exporter with a scrape path of:
                # http://$epHost:$epPort/$TraceOptionNodeName
                hasPrometheus = {
                  # Preserve legacy prometheus binding unless we have a reason to switch
                  # Let's see how the updated nixos node service chooses for defaults.
                  epHost = hostAddr;
                  epPort = cardanoNodePrometheusExporterPort;
                };

                # Real time viewer at https.
                hasRTView = {
                  epHost = "127.0.0.1";
                  epPort = 3300;
                };

                # A cardano-tracer error will be thrown if the logging list is empty of not included.
                logging = [
                  {
                    logFormat = "ForHuman";
                    # logFormat = "ForMachine";

                    # Selecting `JournalMode` seems to force `ForMachine` logFormat even if `ForHuman` is selected.
                    logMode = "JournalMode";
                    # logMode = "FileMode";

                    # /dev/null works, but that seems to destroy some RTView capability as it must be parsing logs.
                    # logRoot = "/dev/null";
                    logRoot = "/tmp/cardano-node-logs";
                  }
                ];

                network = {
                  contents = "/tmp/forwarder.sock";
                  tag = "AcceptAt";
                };

                networkMagic = protocolMagic;
                resourceFreq = null;

                rotation = {
                  rpFrequencySecs = 15;
                  rpKeepFilesNum = 10;
                  rpLogLimitBytes = 1000000000;
                  rpMaxAgeHours = 24;
                };
              });
            };

            systemd.services.cardano-tracer = {
              wantedBy = ["multi-user.target"];
              after = ["network-online.target"];
              environment.HOME = "/var/lib/cardano-tracer";
              serviceConfig = {
                StateDirectory = "cardano-tracer";
                WorkingDirectory = "/var/lib/cardano-tracer";
              };
            };

            services.cardano-node = {
              tracerSocketPathConnect = "/tmp/forwarder.sock";

              # This removes most old tracing system config.
              # It will only leave a minSeverity = "Critical" for the legacy system active.
              useLegacyTracing = false;

              # This appears to do nothing.
              withCardanoTracer = true;

              extraNodeConfig = {
                # This option is what enables the new tracing/metrics system.
                UseTraceDispatcher = true;

                # Default options; further customization can be added per tracer.
                TraceOptions = {
                  "" = {
                    severity = "Notice";
                    detail = "DNormal";
                    backends = [
                      # This results in journald output for the service, like we would normally expect.
                      "Stdout HumanFormatColoured"
                      # "Stdout HumanFormatUncoloured"
                      # "Stdout MachineFormat"

                      # "EKGBackend"
                      "Forwarder"
                    ];
                  };
                };
              };

              extraNodeInstanceConfig = i: {
                # This is important to set, otherwise tracer log files and RTView will get an ugly name.
                TraceOptionNodeName =
                  if (i == 0)
                  then name
                  else "${name}-${toString i}";
              };
            };
          })
        ];
      };
      # netDebug = {
      #   services.cardano-node = {
      #     useNewTopology = false;
      #     extraNodeConfig = {
      #       TraceMux = true;
      #       TraceConnectionManagerTransitions = true;
      #       DebugPeerSelectionInitiator = true;
      #       DebugPeerSelectionInitiatorResponder = true;
      #       options.mapSeverity = {
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
      # # Disable p2p
      # disableP2p = {
      #   services.cardano-node = {
      #     useNewTopology = false;
      #     extraNodeConfig.EnableP2P = false;
      #   };
      # };
      #
      # # Allow legacy group incoming connections on bps if non-p2p testing is required
      # mkBpLegacyFwRules = nodeNameList: {
      #   networking.firewall = {
      #     extraCommands = concatMapStringsSep "\n" (n: "iptables -t filter -I nixos-fw -i ens5 -p tcp -m tcp -s ${n}.${domain} --dport 3001 -j nixos-fw-accept") nodeNameList;
      #     extraStopCommands = concatMapStringsSep "\n" (n: "iptables -t filter -D nixos-fw -i ens5 -p tcp -m tcp -s ${n}.${domain} --dport 3001 -j nixos-fw-accept || true") nodeNameList;
      #   };
      # };
      #
      # # Example add fw rules for relay to block producer connections in non-p2p network setup
      # sancho1bpLegacy = mkBpLegacyFwRules ["sanchonet1-rel-a-1" "sanchonet1-rel-b-1" "sanchonet1-rel-c-1"];
      # sancho2bpLegacy = mkBpLegacyFwRules ["sanchonet2-rel-a-1" "sanchonet2-rel-b-1" "sanchonet2-rel-c-1"];
      # sancho3bpLegacy = mkBpLegacyFwRules ["sanchonet3-rel-a-1" "sanchonet3-rel-b-1" "sanchonet3-rel-c-1"];
      #
      # extraProd = producerList: {services.cardano-node-topology.extraNodeListProducers = producerList;};
      #
      # # A legacy machine will need to have at least partial peer mesh to other groups, example:
      # sanchonet1-rel-a-1 = {imports = [ <...> disableP2p (extraProd ["sanchonet2-rel-a-1" "sanchonet3-rel-a-1"])];};
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
      preprod1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preprod1") node bp (declMRel "preprod1-rel-a-1")];};
      preprod1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preprod1") node rel preprodRelMig mithrilRelay (declMSigner "preprod1-bp-a-1")];};
      preprod1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "preprod1") node rel preprodRelMig];};
      preprod1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "preprod1") node rel preprodRelMig];};
      preprod1-dbsync-a-1 = {imports = [eu-central-1 m5a-large (ebs 100) (group "preprod1") dbsync smash preprodSmash];};
      preprod1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preprod1") node faucet preprodFaucet];};

      preprod2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "preprod2") node bp (declMRel "preprod2-rel-b-1")];};
      preprod2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preprod2") node rel preprodRelMig];};
      preprod2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "preprod2") node rel preprodRelMig mithrilRelay (declMSigner "preprod2-bp-b-1")];};
      preprod2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "preprod2") node rel preprodRelMig];};

      preprod3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "preprod3") node bp pre (declMRel "preprod3-rel-c-1")];};
      preprod3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preprod3") node rel pre preprodRelMig];};
      preprod3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "preprod3") node rel pre preprodRelMig];};
      preprod3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "preprod3") node rel pre preprodRelMig mithrilRelay (declMSigner "preprod3-bp-c-1")];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Preview, one-third on release tag, two-thirds on pre-release tag
      preview1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preview1") node bp (declMRel "preview1-rel-a-1")];};
      preview1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preview1") node rel previewRelMig mithrilRelay (declMSigner "preview1-bp-a-1")];};
      preview1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "preview1") node rel previewRelMig];};
      preview1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "preview1") node rel previewRelMig];};
      preview1-dbsync-a-1 = {imports = [eu-central-1 r5-large (ebs 100) (group "preview1") dbsync smash previewSmash];};
      preview1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preview1") node faucet previewFaucet];};

      preview2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "preview2") node bp pre (declMRel "preview2-rel-b-1")];};
      preview2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preview2") node rel pre previewRelMig];};
      preview2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "preview2") node rel pre previewRelMig mithrilRelay (declMSigner "preview2-bp-b-1")];};
      preview2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "preview2") node rel pre previewRelMig];};

      preview3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "preview3") node bp pre (declMRel "preview3-rel-c-1")];};
      preview3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "preview3") node rel pre previewRelMig];};
      preview3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "preview3") node rel pre previewRelMig];};
      preview3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "preview3") node rel pre previewRelMig mithrilRelay (declMSigner "preview3-bp-c-1")];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Private, pre-release--include-all-instances
      # All private nodes stopped until chain truncation and respin in the near future
      private1-bp-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "private1") node bp disableAlertCount];};
      private1-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "private1") node rel disableAlertCount];};
      private1-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 80) (group "private1") node rel disableAlertCount];};
      private1-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 80) (group "private1") node rel disableAlertCount];};
      private1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "private1") dbsync nixosModules.govtool-backend disableAlertCount];};
      private1-faucet-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "private1") node faucet privateFaucet disableAlertCount];};

      private2-bp-b-1 = {imports = [eu-west-1 t3a-small (ebs 80) (group "private2") node bp disableAlertCount];};
      private2-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "private2") node rel disableAlertCount];};
      private2-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 80) (group "private2") node rel disableAlertCount];};
      private2-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 80) (group "private2") node rel disableAlertCount];};

      private3-bp-c-1 = {imports = [us-east-2 t3a-small (ebs 80) (group "private3") node bp disableAlertCount];};
      private3-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "private3") node rel disableAlertCount];};
      private3-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 80) (group "private3") node rel disableAlertCount];};
      private3-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 80) (group "private3") node rel disableAlertCount];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Sanchonet, pre-release
      sanchonet1-bp-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "sanchonet1") node bp (declMRel "sanchonet1-rel-a-1")];};
      sanchonet1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "sanchonet1") node rel sanchoRelMig mithrilRelay (declMSigner "sanchonet1-bp-a-1")];};
      sanchonet1-rel-a-2 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "sanchonet1") node rel sanchoRelMig];};
      sanchonet1-rel-a-3 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "sanchonet1") node rel sanchoRelMig];};
      # Temporarily disable dbsync until dbsync has 8.10.0 availability
      sanchonet1-dbsync-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "sanchonet1") dbsync smash sanchoSmash];};
      sanchonet1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "sanchonet1") node faucet sanchoFaucet faucetTmpFix];};
      sanchonet1-test-a-1 = {imports = [eu-central-1 t3a-medium (ebs 80) (group "sanchonet1") node newMetrics];};

      sanchonet2-bp-b-1 = {imports = [eu-west-1 t3a-small (ebs 80) (group "sanchonet2") node bp (declMRel "sanchonet2-rel-b-1")];};
      sanchonet2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "sanchonet2") node rel sanchoRelMig mithrilRelay (declMSigner "sanchonet2-bp-b-1")];};
      sanchonet2-rel-b-2 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "sanchonet2") node rel sanchoRelMig];};
      sanchonet2-rel-b-3 = {imports = [eu-west-1 t3a-medium (ebs 80) (group "sanchonet2") node rel sanchoRelMig];};

      sanchonet3-bp-c-1 = {imports = [us-east-2 t3a-small (ebs 80) (group "sanchonet3") node newMetrics bp (declMRel "sanchonet3-rel-c-1")];};
      sanchonet3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 80) (group "sanchonet3") node rel sanchoRelMig mithrilRelay (declMSigner "sanchonet3-bp-c-1")];};
      sanchonet3-rel-c-2 = {imports = [us-east-2 t3a-medium (ebs 80) (group "sanchonet3") node rel sanchoRelMig];};
      sanchonet3-rel-c-3 = {imports = [us-east-2 t3a-medium (ebs 80) (group "sanchonet3") node newMetrics rel sanchoRelMig];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Shelley-qa, pre-release
      shelley-qa1-bp-a-1 = {imports = [eu-central-1 t3a-micro (ebs 80) (group "shelley-qa1") node bp];};
      shelley-qa1-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 80) (group "shelley-qa1") node rel];};
      shelley-qa1-rel-a-2 = {imports = [eu-central-1 t3a-micro (ebs 80) (group "shelley-qa1") node rel];};
      shelley-qa1-rel-a-3 = {imports = [eu-central-1 t3a-micro (ebs 80) (group "shelley-qa1") node rel];};
      shelley-qa1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "shelley-qa1") dbsync pre smash shelleySmash];};
      shelley-qa1-faucet-a-1 = {imports = [eu-central-1 t3a-micro (ebs 80) (group "shelley-qa1") node faucet shelleyFaucet];};

      shelley-qa2-bp-b-1 = {imports = [eu-west-1 t3a-micro (ebs 80) (group "shelley-qa2") node bp];};
      shelley-qa2-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 80) (group "shelley-qa2") node rel];};
      shelley-qa2-rel-b-2 = {imports = [eu-west-1 t3a-micro (ebs 80) (group "shelley-qa2") node rel];};
      shelley-qa2-rel-b-3 = {imports = [eu-west-1 t3a-micro (ebs 80) (group "shelley-qa2") node rel];};

      shelley-qa3-bp-c-1 = {imports = [us-east-2 t3a-micro (ebs 80) (group "shelley-qa3") node bp];};
      shelley-qa3-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 80) (group "shelley-qa3") node rel];};
      shelley-qa3-rel-c-2 = {imports = [us-east-2 t3a-micro (ebs 80) (group "shelley-qa3") node rel];};
      shelley-qa3-rel-c-3 = {imports = [us-east-2 t3a-micro (ebs 80) (group "shelley-qa3") node rel];};
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
      mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node (openFwTcp 3001)];};

      # Also keep the lmdb and extra debug mainnet node in stopped state for now
      mainnet1-rel-a-2 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node (openFwTcp 3001) nodeHd lmdb ram8gib disableAlertCount];};
      mainnet1-rel-a-3 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node (openFwTcp 3001) nodeHd lmdb ram8gib disableAlertCount];};
      mainnet1-rel-a-4 = {imports = [eu-central-1 r5-large (ebs 300) (group "mainnet1") netDebug node disableAlertCount];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Misc
      misc1-metadata-a-1 = {imports = [eu-central-1 t3a-small (ebs 80) (group "misc1") metadata];};
      misc1-webserver-a-1 = {imports = [eu-central-1 t3a-micro (ebs 80) (group "misc1") webserver];};
      # ---------------------------------------------------------------------------------------------------------
    };
  }
