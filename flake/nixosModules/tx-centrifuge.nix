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

      maxRuntimeSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 4200;
        description = ''
          Maximum wall-clock seconds a single tx-centrifuge invocation is
          allowed to run before systemd terminates it with SIGTERM.

          This is a backstop, not the normal way a window ends: keep it above
          the gap between startOnCalendar and stopOnCalendar so the stop timer
          gets there first. An explicit stop is the safer path, because
          systemd does not apply Restart to a unit it was told to stop, so the
          load cannot bounce back inside the off hour whatever exit status the
          process reports. Lengthening the window via the calendars means
          raising this too.

          Long benchmark runs accumulate state (pending-recycle map growth, GC
          fragmentation, file descriptor churn from observer reconnects); a
          periodic forced restart bounds those effects and makes each run a
          fresh, stateless attempt. Initial UTxOs are re-discovered on every
          startup, so there is no state to lose across restarts.

          Set to 0 to disable the time limit entirely.
        '';
      };

      startOnCalendar = lib.mkOption {
        type = lib.types.str;
        default = "00/2:00:00";
        description = ''
          systemd OnCalendar expression for the timer that starts the load
          window. The default fires at the top of every even hour, which
          together with stopOnCalendar gives a 50% duty cycle aligned to the
          wall clock: load on for even hours, off for odd hours.

          Clock alignment is the point. A cycle built from runtime caps and
          restart delays drifts by the startup time plus RestartSec on every
          iteration, so the on window walks around the clock and other teams
          cannot plan their own load runs against it.

          The timer is not Persistent, so a host that boots mid-window waits
          for the next start rather than firing a missed one immediately and
          putting load into an odd hour.
        '';
      };

      stopOnCalendar = lib.mkOption {
        type = lib.types.str;
        default = "01/2:00:00";
        description = ''
          systemd OnCalendar expression for the timer that ends the load
          window, by default the top of every odd hour.

          This is what holds the window edge when a crash restart has reset
          the runtime cap mid-window: maxRuntimeSeconds alone would let that
          restart run a further full cap past the boundary.
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

        systemd.timers = {
          # Started by the timer below, not at boot: a boot inside an odd hour
          # must not put load on the network until the next even hour.
          ${serviceName} = {
            wantedBy = ["timers.target"];
            timerConfig = {
              OnCalendar = cfg.startOnCalendar;
              # Default accuracy is 1 minute, which would jitter the window edge.
              AccuracySec = "1s";
              Persistent = false;
            };
          };
          # Ends the window on the clock. A clean stop is not a failure, so
          # Restart does not fire and the service waits for the next timer.
          "${serviceName}-stop" = {
            wantedBy = ["timers.target"];
            timerConfig = {
              OnCalendar = cfg.stopOnCalendar;
              AccuracySec = "1s";
              Persistent = false;
            };
          };
        };

        systemd.services = {
          ${serviceName} = {
            enableStrictShellChecks = true;

            # Restart on failure: up to 3 retries, 1 minute apart. After 3
            # failed retries within the 10-minute window the unit stays in
            # 'failed' state until a manual `systemctl reset-failed` /
            # `start`. Initial start counts toward the burst, so 4 total
            # start attempts (initial + 3 retries) are permitted. Only true
            # crash restarts feed the burst: ending a window is a SIGTERM,
            # which RestartPreventExitStatus below excludes.
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

              # Keeps a window ending from looking like a crash. Both the
              # runtime cap and the stop timer end the run with SIGTERM, and
              # without this Restart=on-failure would bring the load straight
              # back up inside the off hour. Genuine crashes carry an exit code
              # or another signal and still restart.
              RestartPreventExitStatus = "SIGTERM";

              # Ends the load window, and bounds state accumulation across the
              # run. Set cfg.maxRuntimeSeconds = 0 to disable — systemd's
              # disable value is "infinity", not 0 (0 would terminate the
              # service immediately).
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

          "${serviceName}-stop" = {
            description = "Stop ${serviceName} at the end of its load window";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.systemd}/bin/systemctl stop ${serviceName}.service";
            };
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
