{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (config.flake) nixosModules nixosConfigurations;
  inherit (config.flake.cardano-parts.cluster.infra.aws) domain;
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
      r5-xlarge.aws.instance.instance_type = "r5.xlarge";
      r5-2xlarge.aws.instance.instance_type = "r5.2xlarge";

      # Helper fns:
      ebs = size: {aws.instance.root_block_device.volume_size = mkDefault size;};
      # ebsIops = iops: {aws.instance.root_block_device.iops = mkDefault iops;};
      # ebsTp = tp: {aws.instance.root_block_device.throughput = mkDefault tp;};
      # ebsHighPerf = recursiveUpdate (ebsIops 10000) (ebsTp 1000);

      # Helper defs:
      # delete.aws.instance.count = 0;

      # Cardano group assignments:
      group = name: {
        cardano-parts.cluster.group = config.flake.cardano-parts.cluster.groups.${name};

        # Since all machines are assigned a group, this is a good place to include default aws instance tags
        aws.instance.tags = {
          inherit (config.flake.cardano-parts.cluster.infra.generic) organization tribe function repo;
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
      declMRel = privateIp: {services.mithril-signer.relayEndpoint = privateIp;};
      declMSigner = privateIp: {services.mithril-relay.signerIp = privateIp;};

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

      openFwTcp3001 = {networking.firewall.allowedTCPPorts = [3001];};

      vva-be = {
        imports = [
          (nixos @ {
            pkgs,
            lib,
            name,
            ...
          }: let
            inherit (groupCfg) groupName groupFlake meta;
            inherit (meta) environmentName;
            inherit (opsLib) mkSopsSecret;

            groupOutPath = groupFlake.self.outPath;
            groupCfg = nixos.config.cardano-parts.cluster.group;
            opsLib = config.flake.cardano-parts.lib.opsLib nixos.pkgs;
          in {
            environment.systemPackages = [inputs.govtool.packages.x86_64-linux.vva-be];

            systemd.services.vva-be = {
              wantedBy = ["multi-user.target"];
              after = ["network-online.target" "postgresql.service"];
              startLimitIntervalSec = 0;
              serviceConfig = {
                ExecStart = lib.getExe (pkgs.writeShellApplication {
                  name = "vva-be";
                  runtimeInputs = [inputs.govtool.packages.x86_64-linux.vva-be];
                  text = "vva-be -c /run/secrets/vva-be-cfg.json start-app";
                });
                Restart = "always";
                RestartSec = "30s";
              };
            };

            users.users.vva-be = {
              isSystemUser = true;
              group = "vva-be";
            };

            users.groups.vva-be = {};

            sops.secrets = mkSopsSecret {
              secretName = "vva-be-cfg.json";
              keyName = "${name}-vva-be.json";
              inherit groupOutPath groupName;
              fileOwner = "vva-be";
              fileGroup = "vva-be";
              restartUnits = ["vva-be.service"];
            };

            networking.firewall.allowedTCPPorts = [80 443];

            security.acme = {
              acceptTerms = true;
              defaults = {
                email = "devops@iohk.io";
                server =
                  if true
                  then "https://acme-v02.api.letsencrypt.org/directory"
                  else "https://acme-staging-v02.api.letsencrypt.org/directory";
              };
            };

            # services.nginx-vhost-exporter.enable = true;

            services.nginx = {
              enable = true;
              eventsConfig = "worker_connections 4096;";
              appendConfig = "worker_rlimit_nofile 16384;";
              recommendedGzipSettings = true;
              recommendedOptimisation = true;
              recommendedProxySettings = true;

              commonHttpConfig = ''
                log_format x-fwd '$remote_addr - $remote_user [$time_local] '
                                 '"$scheme://$host" "$request" "$http_accept_language" $status $body_bytes_sent '
                                 '"$http_referer" "$http_user_agent" "$http_x_forwarded_for"';

                access_log syslog:server=unix:/dev/log x-fwd;
                limit_req_zone $binary_remote_addr zone=apiPerIP:100m rate=1r/s;
                limit_req_status 429;
              '';

              virtualHosts = {
                vva-be = {
                  serverName = "${name}.${domain}";
                  serverAliases = ["${environmentName}-govtool.${domain}" "${environmentName}-explorer.${domain}" "${environmentName}-smash.${domain}"];

                  default = true;
                  enableACME = true;
                  forceSSL = true;

                  locations = {
                    "/".proxyPass = "http://127.0.0.1:9999";
                    "/api/".proxyPass = "http://127.0.0.1:9999/";
                  };
                };
              };
            };

            systemd.services.nginx.serviceConfig = {
              LimitNOFILE = 65535;
              LogNamespace = "nginx";
            };
          })
        ];
      };

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

      nodeBootstrap = {
        imports = [
          {
            cardano-parts.perNode.pkgs = {
              inherit (inputs.cardano-node-bootstrap.packages.x86_64-linux) cardano-cli cardano-node cardano-submit-api;
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
          }
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
      bp = {imports = [inputs.cardano-parts.nixosModules.role-block-producer topoBp];};
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
      # TODO: The ledger after slot modification is to be removed after the first few days of sanchonet respin on 2024-02-10
      sanchoRelMig = recursiveUpdate (mkWorldRelayMig 30004) {services.cardano-node.usePeersFromLedgerAfterSlot = 20908800;};
      #
      # multiInst = {services.cardano-node.instances = 2;};
      #
      # # p2p and legacy network debugging code
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
        inputs.cardano-parts.nixosModules.module-cardano-parts
        inputs.cardano-parts.nixosModules.profile-basic
        inputs.cardano-parts.nixosModules.profile-common
        inputs.cardano-parts.nixosModules.profile-grafana-agent
        nixosModules.common
      ];

      # Setup cardano-world networks:
      # ---------------------------------------------------------------------------------------------------------
      # Preprod, two-thirds on release tag, one-third on pre-release tag
      preprod1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod1") node bp pre (declMRel "172.31.42.6")];};
      preprod1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod1") node rel pre preprodRelMig mithrilRelay (declMSigner "172.31.43.63")];};
      preprod1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod1") node rel pre preprodRelMig];};
      preprod1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod1") node rel pre preprodRelMig];};
      preprod1-dbsync-a-1 = {imports = [eu-central-1 m5a-large (ebs 100) (group "preprod1") dbsync smash pre preprodSmash];};
      preprod1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod1") node faucet pre preprodFaucet];};

      preprod2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod2") node bp pre (declMRel "172.31.45.137")];};
      preprod2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod2") node rel pre preprodRelMig];};
      preprod2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod2") node rel pre preprodRelMig mithrilRelay (declMSigner "172.31.44.71")];};
      preprod2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod2") node rel pre preprodRelMig];};

      preprod3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod3") node bp pre (declMRel "172.31.32.40")];};
      preprod3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preprod3") node rel pre preprodRelMig];};
      preprod3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preprod3") node rel pre preprodRelMig];};
      preprod3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preprod3") node rel pre preprodRelMig mithrilRelay (declMSigner "172.31.37.171")];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Preview, one-third on release tag, two-thirds on pre-release tag
      preview1-bp-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node bp pre (declMRel "172.31.43.156")];};
      preview1-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node rel pre previewRelMig mithrilRelay (declMSigner "172.31.46.81")];};
      preview1-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview1") node rel pre previewRelMig];};
      preview1-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview1") node rel pre previewRelMig];};
      preview1-dbsync-a-1 = {imports = [eu-central-1 m5a-large (ebs 100) (group "preview1") dbsync smash pre previewSmash];};
      preview1-faucet-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview1") node faucet pre previewFaucet];};

      preview2-bp-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview2") node bp pre (declMRel "172.31.34.161")];};
      preview2-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview2") node rel pre previewRelMig];};
      preview2-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview2") node rel pre previewRelMig mithrilRelay (declMSigner "172.31.34.130")];};
      preview2-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview2") node rel pre previewRelMig];};

      preview3-bp-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview3") node bp pre (declMRel "172.31.34.147")];};
      preview3-rel-a-1 = {imports = [eu-central-1 t3a-medium (ebs 40) (group "preview3") node rel pre previewRelMig];};
      preview3-rel-b-1 = {imports = [eu-west-1 t3a-medium (ebs 40) (group "preview3") node rel pre previewRelMig];};
      preview3-rel-c-1 = {imports = [us-east-2 t3a-medium (ebs 40) (group "preview3") node rel pre previewRelMig mithrilRelay (declMSigner "172.31.36.174")];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Private, pre-release
      private1-bp-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "private1") node bp];};
      private1-rel-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "private1") node rel];};
      private1-rel-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "private1") node rel];};
      private1-rel-c-1 = {imports = [us-east-2 t3a-micro (ebs 40) (group "private1") node rel];};
      private1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "private1") dbsync vva-be];};
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
      sanchonet1-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "sanchonet1") node rel sanchoRelMig];};
      sanchonet1-rel-b-1 = {imports = [eu-west-1 t3a-small (ebs 40) (group "sanchonet1") node rel sanchoRelMig];};
      sanchonet1-rel-c-1 = {imports = [us-east-2 t3a-small (ebs 40) (group "sanchonet1") node rel sanchoRelMig];};
      sanchonet1-dbsync-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "sanchonet1") dbsync smash sanchoSmash];};
      sanchonet1-faucet-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "sanchonet1") node faucet sanchoFaucet];};
      sanchonet1-test-a-1 = {imports = [eu-central-1 r5-xlarge (ebs 40) (group "sanchonet1") node];};

      sanchonet2-bp-b-1 = {imports = [eu-west-1 t3a-micro (ebs 40) (group "sanchonet2") node bp];};
      sanchonet2-rel-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "sanchonet2") node rel sanchoRelMig];};
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
      # Rel-a-1 is set up as a fake block producer for gc latency testing during ledger snapshots
      # Rel-a-{2,3} lmdb and mdb fault tests
      # Rel-a-4 addnl current release tests
      # Dbsync-a-2 is kept in stopped state unless actively needed for testing
      mainnet1-dbsync-a-1 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync pre];};
      mainnet1-dbsync-a-2 = {imports = [eu-central-1 r5-2xlarge (ebs 1000) (group "mainnet1") dbsync];};

      # mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node nodeGhc963 openFwTcp3001 bp gcLogging rtsOptMods];};
      # mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node nodeGhc963 openFwTcp3001];};
      mainnet1-rel-a-1 = {imports = [eu-central-1 m5a-2xlarge (ebs 300) (group "mainnet1") node openFwTcp3001];};
      mainnet1-rel-a-2 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node openFwTcp3001 nodeHd lmdb ram8gib];};
      mainnet1-rel-a-3 = {imports = [eu-central-1 m5a-large (ebs 300) (group "mainnet1") node openFwTcp3001 nodeHd lmdb ram8gib];};
      mainnet1-rel-a-4 = {imports = [eu-central-1 r5-large (ebs 300) (group "mainnet1") node nodeBootstrap];};
      # ---------------------------------------------------------------------------------------------------------

      # ---------------------------------------------------------------------------------------------------------
      # Misc
      misc1-metadata-a-1 = {imports = [eu-central-1 t3a-small (ebs 40) (group "misc1") metadata];};
      misc1-webserver-a-1 = {imports = [eu-central-1 t3a-micro (ebs 40) (group "misc1") webserver];};
      # ---------------------------------------------------------------------------------------------------------
    };
  }
