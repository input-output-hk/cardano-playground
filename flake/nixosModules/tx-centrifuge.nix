{moduleWithSystem, ...}: {
  flake.nixosModules.cardano-tx-centrifuge = moduleWithSystem ({inputs'}: {
    config,
    pkgs,
    lib,
    ...
  }: let
    inherit (lib) mkDefault;

    serviceName = "cardano-tx-centrifuge";
    settingsFormat = pkgs.formats.json {};
    cfg = config.services.cardano-tx-centrifuge;
  in {
    options.services.${serviceName} = {
      enable = lib.mkEnableOption "tx-centrifuge";

      package = lib.mkPackageOption inputs'.cardano-node-leios-bench.packages "tx-centrifuge" {};

      useLocalCardanoNode = {
        nodeConfig =
          lib.mkEnableOption ''
            using the local cardano-node's config and its N2C socket as a
            'nodetoclient' observer. The observer is REQUIRED for initial
            UTxO discovery on every startup; if you disable this flag you
            must add an observer via 'settings.observers' yourself.
          ''
          // {
            default = config.services.cardano-node.enable;
          };

        recycling =
          lib.mkEnableOption ''
            using on_confirm recycling via the local observer (depth 2).
            Independent of the discovery use; you can have the observer for
            discovery only and still pick a different recycle strategy
            (on_pull / on_build) via settings.builder.recycle.
          ''
          // {
            default = config.services.cardano-node.enable;
          };
      };

      signingKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path at runtime to the recycle signing key for tx-centrifuge. This
          key derives every recycle address (the supplied key is workload
          0's; subsequent workloads derive from it). The operator must fund
          at least workload 0's bech32 address before starting the service.

          Initial UTxOs are discovered on-chain at every startup via a
          QueryUTxOByAddress against the local node — there is no separate
          funds.json. Restarts are stateless.
        '';
      };

      cooldownSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = ''
          Seconds tx-centrifuge waits after the builder has begun filling
          the payload queue and before workers connect to their target
          nodes. Use a non-zero value for multi-node benchmark clusters
          where you want the cluster to stabilise before traffic begins
          (so transmission ramps to the target TPS instantly). Leave at 0
          for ops / single-node deployments.
        '';
      };

      settings = lib.mkOption {
        inherit (settingsFormat) type;
        default = {};
        description = "Overrides deep-merged on top of the module defaults for centrifuge.json.";
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        services.${serviceName}.settings = {
          # Resolved by systemd's LoadCredential below. Keep in sync with
          # the unit name (serviceName) and credential name (funds.skey).
          signing_key_file = "/run/credentials/${serviceName}.service/funds.skey";

          cooldown_seconds = cfg.cooldownSeconds;

          builder = {
            type = "value";
            params = {
              inputs_per_tx = lib.mkDefault 1;
              outputs_per_tx = lib.mkDefault 1;
              fee = lib.mkDefault 1000000;
            };
          };

          rate_limit = {
            type = lib.mkDefault "token_bucket";
            scope = lib.mkDefault "shared";
            params.tps = lib.mkDefault 100;
          };

          max_batch_size = lib.mkDefault 10;
        };

        systemd.services.${serviceName} = {
          wantedBy = ["multi-user.target"];

          enableStrictShellChecks = true;

          # Restart on failure: up to 3 retries, 1 minute apart. After 3
          # failed retries within the 10-minute window the unit stays in
          # 'failed' state until a manual `systemctl reset-failed` /
          # `start`. Initial start counts toward the burst, so 4 total
          # start attempts (initial + 3 retries) are permitted.
          startLimitBurst = 4;
          startLimitIntervalSec = 600;

          serviceConfig = {
            ExecStart = toString [
              (lib.getExe cfg.package)
              (settingsFormat.generate "centrifuge.json" cfg.settings)
            ];

            DynamicUser = true;

            LoadCredential = [
              "funds.skey:${cfg.signingKeyFile}"
            ];

            Restart = "on-failure";
            RestartSec = 60;

            # Disable journald rate-limiting on this unit. At high TPS the
            # trace-dispatcher emits thousands of lines per second; the
            # systemd default (10000 in 30s) would silently drop most of
            # them after the first 30 seconds of a run.
            LogRateLimitIntervalSec = 0;
            LogRateLimitBurst = 0;
          };
        };
      }

      (lib.mkIf cfg.useLocalCardanoNode.nodeConfig {
        services = {
          ${serviceName}.settings = {
            nodeConfig = with config.services.cardano-node;
              mkDefault (if nodeConfigFile != null
              then nodeConfigFile
              else pkgs.writers.writeJSON "node-config.json" nodeConfig);

            # The local nodetoclient observer is used for initial UTxO
            # discovery on every startup, regardless of the recycle
            # strategy chosen below. Always present when the local node is
            # configured.
            observers.local-follower = {
              type = mkDefault "nodetoclient";
              params = {
                confirmation_depth = mkDefault 2;
                socket_path = mkDefault (config.services.cardano-node.socketPath 0);
              };
            };
          };

          cardano-node.shareNodeSocket = mkDefault true;
        };

        systemd.services.${serviceName} = rec {
          requisite = [
            "cardano-node.service"
            "cardano-node-socket-share.service"
          ];
          after = requisite;

          serviceConfig.SupplementaryGroups = lib.singleton config.services.cardano-node.socketGroup;
        };
      })

      (lib.mkIf cfg.useLocalCardanoNode.recycling {
        services.${serviceName}.settings.builder.recycle = {
          type = mkDefault "on_confirm";
          params = mkDefault "local-follower";
        };
      })
    ]);
  });
}
