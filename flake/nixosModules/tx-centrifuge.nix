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

      recycleTimeoutBlocks = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = ''
          Block-depth threshold for the timeout sweeper. A pending-recycle
          entry whose submission tip block is more than this many blocks
          behind the current tip is timed out: the runtime calls
          'onTimeout', which either recycles the original inputs back to
          the input queue or drops them based on the per-input retry cap.

          0 disables the sweeper entirely (the upstream default). The
          default 60 is ~20 minutes at average block production, well
          within the ~1 hr window before input exhaustion if the sweeper
          is off. Increase or decrease to trade recovery latency against
          the spend-race hazard: a tx that lands on-chain *after* its
          inputs are recycled will produce a follow-up tx that the node
          rejects, and that input also re-times out until
          'recycleMaxRetries' gives up on it.
        '';
      };

      recycleMaxRetries = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3;
        description = ''
          Per-input cap on consecutive timeouts. The runtime drops the
          input on the Nth timeout (counting from 1), so values 1+ are
          meaningful. The default 3 means each UTxO is allowed two
          recycles via the timeout path before being given up on
          permanently.

          Has no effect when 'recycleTimeoutBlocks' is 0.
        '';
      };

      maxRuntimeSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2 * 3600;
        description = ''
          Maximum wall-clock seconds a single tx-centrifuge invocation is
          allowed to run before systemd terminates it (SIGTERM → SIGKILL
          after TimeoutStopSec). The unit transitions to 'failed' state on
          expiry, which the existing Restart=on-failure policy then handles
          — so the service restarts automatically after RestartSec.

          Long benchmark runs accumulate state (pending-recycle map growth, GC
          fragmentation, file descriptor churn from observer reconnects); a
          periodic forced restart bounds those effects and makes each run a
          fresh, stateless attempt. Initial UTxOs are re-discovered on every
          startup, so there is no state to lose across restarts.

          Set to 0 to disable the time limit entirely.
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
          recycle_timeout_blocks = cfg.recycleTimeoutBlocks;
          recycle_max_retries = cfg.recycleMaxRetries;

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

            # Forced restart to bound state accumulation across long runs. On
            # expiry, systemd terminates the process and marks the unit as
            # 'failed', which Restart=on-failure above then handles.
            # RestartSec=60 governs the post-expiry gap. Set
            # cfg.maxRuntimeSeconds = 0 to disable — systemd's disable value is
            # "infinity", not 0 (0 would terminate the service immediately).
            RuntimeMaxSec =
              if cfg.maxRuntimeSeconds == 0
              then "infinity"
              else cfg.maxRuntimeSeconds;

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
              mkDefault (
                if nodeConfigFile != null
                then nodeConfigFile
                else pkgs.writers.writeJSON "node-config.json" nodeConfig
              );

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
