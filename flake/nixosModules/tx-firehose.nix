{moduleWithSystem, ...}: {
  flake.nixosModules.cardano-tx-firehose = moduleWithSystem ({inputs'}: {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (lib) mkDefault mkIf mkOption optionals types;

    serviceName = "cardano-tx-firehose";
    cfg = config.services.cardano-tx-firehose;

    credential = credName: "/run/credentials/${serviceName}.service/${credName}";

    # One node per host. A multi-instance node names its units
    # cardano-node-N.service, which these would miss.
    nodeUnit = "cardano-node.service";

    # Makes the node socket group writable, and is WantedBy the node, so it
    # only starts when the node does. Pulled in rather than required, because a
    # node already running from before this module was deployed never picked up
    # that want and the socket stays unwritable.
    socketUnit = "cardano-node-socket-share.service";
  in {
    options.services.${serviceName} = {
      enable = lib.mkEnableOption "tx-firehose";

      # From the same pin as the node rather than the bench pin, which trails
      # it. The generator and the node it submits into should move together.
      package = lib.mkPackageOption inputs'.cardano-node-leios.packages "tx-firehose-static" {};

      socketPath = mkOption {
        type = types.path;
        default = config.services.cardano-node.socketPath 0;
        defaultText = lib.literalExpression "config.services.cardano-node.socketPath 0";
        description = ''
          Node to client socket tx-firehose submits through. It is the only
          connection tx-firehose opens, there is no node to node path.
        '';
      };

      testnetMagic = mkOption {
        type = types.ints.unsigned;
        description = "Network magic of the chain being loaded.";
      };

      signingKeyFile = mkOption {
        type = types.path;
        description = ''
          Runtime path to the payment signing key. Its derived address holds
          the entire fund set and must be funded before the first start,
          because tx-firehose exits when the startup UTxO query comes back
          empty.

          UTxOs are rediscovered on every start, so restarts carry no state.
        '';
      };

      stakingKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Runtime path to a stake signing key. Only its verification key hash
          is used, to derive a base address in place of the default enterprise
          one. A load generator has no reason to delegate, and the enterprise
          address is 28 bytes smaller per output.
        '';
      };

      tps = mkOption {
        type = types.number;
        default = 100;
        description = ''
          Submission rate ceiling. tx-firehose holds one transaction in flight
          and sleeps 1/tps after each reply, so the achieved rate is bounded by
          the round trip as well, and raising this past that bound changes
          nothing. Add instances on separate keys to go faster.
        '';
      };

      fee = mkOption {
        type = types.ints.unsigned;
        default = 200000;
        description = ''
          Fixed fee per transaction. tx-firehose does no fee calculation, so
          this must clear the protocol minimum for the transaction shape that
          outputsPerTx produces. At minFeeA 44 and minFeeB 155381 a one in one
          out transaction needs 165413, and a coloured one 167393.

          Fee is also the entire burn rate, since every transaction returns its
          inputs less this amount to the same address. At 100 tps this spends
          20 ada per second of load.
        '';
      };

      outputsPerTx = mkOption {
        type = types.ints.positive;
        default = 1;
        description = ''
          Outputs per transaction. With inputsPerTx unset the input count is
          derived to hold the fund set at this size, so the steady state is
          this many in and this many out.

          Raising it requires raising fee to match the larger transaction.
          Underpaying is not self correcting: the rejection keeps the inputs,
          selection is deterministic, so the identical transaction is rebuilt
          and rejected until the unit gives up, and the restart lands in the
          same state.
        '';
      };

      inputsPerTx = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          Pin the input count instead of deriving it. The fund set then grows
          or shrinks with every transaction, and tx-firehose exits once fewer
          than this many funds remain.
        '';
      };

      maxConsecutiveErrors = mkOption {
        type = types.ints.positive;
        default = 50;
        description = "Consecutive rejects before exiting for a restart.";
      };

      color = mkOption {
        type = types.nullOr types.str;
        default = "auto";
        example = "ff0000";
        description = ''
          Tag every transaction with this RGB hex in metadata label 1022, so a
          mempool observer can attribute each one to the generator that made
          it. The default derives the colour from the signing key, which is
          stable across restarts and needs no per host assignment.

          Auto draws from about 1500 distinguishable hues and can collide, so
          set explicit colours for a run whose point is telling generators
          apart. Set to null to submit untagged.

          Metadata costs roughly 45 bytes per transaction, so a coloured run is
          not byte comparable with an uncoloured baseline.
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra arguments appended to the tx-firehose invocation.";
      };

      maxRuntimeSeconds = mkOption {
        type = types.ints.unsigned;
        default = 4200;
        description = ''
          Backstop on a single invocation, terminated with SIGTERM. Keep it
          above the gap between startOnCalendar and stopOnCalendar so the stop
          timer ends the window first, which is safer because systemd applies
          no restart to a unit it was told to stop.

          Set to 0 to disable.
        '';
      };

      startOnCalendar = mkOption {
        type = types.str;
        default = "00/2:00:00";
        description = ''
          systemd OnCalendar expression starting the load window, by default
          the top of every even hour. This matches cardano-tx-centrifuge, so
          the two generators load the network together rather than smearing
          across each other's quiet hours.

          The timer is not Persistent, so a host booting mid window waits for
          the next start instead of putting load into an odd hour.
        '';
      };

      stopOnCalendar = mkOption {
        type = types.str;
        default = "01/2:00:00";
        description = ''
          systemd OnCalendar expression ending the load window, by default the
          top of every odd hour. This is what holds the window edge when a
          restart has reset the runtime cap mid window.
        '';
      };
    };

    config = mkIf cfg.enable {
      services.cardano-node.shareNodeSocket = mkDefault true;

      systemd.timers = {
        ${serviceName} = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = cfg.startOnCalendar;
            # Default accuracy is 1 minute, which would jitter the window edge.
            AccuracySec = "1s";
            Persistent = false;
          };
        };

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
          # Exiting and restarting is normal here, not a fault: a reject that
          # drops the last fund ends the run cleanly. Budget enough restarts to
          # cover a window while still failing visibly on a key that was never
          # funded, which exits immediately and burns the whole burst.
          startLimitBurst = 20;
          startLimitIntervalSec = 3600;

          requisite = [nodeUnit];
          wants = [socketUnit];
          after = [nodeUnit socketUnit];

          serviceConfig = {
            SupplementaryGroups = lib.singleton config.services.cardano-node.socketGroup;

            ExecStart = toString (
              [
                (lib.getExe' cfg.package "tx-firehose")
                "--socket-path"
                cfg.socketPath
                "--testnet-magic"
                (toString cfg.testnetMagic)
                "--signing-key-file"
                (credential "funds.skey")
                "--tps"
                (toString cfg.tps)
                "--fee"
                (toString cfg.fee)
                "--outputs-per-tx"
                (toString cfg.outputsPerTx)
                "--max-consecutive-errors"
                (toString cfg.maxConsecutiveErrors)
              ]
              ++ optionals (cfg.stakingKeyFile != null) ["--staking-key-file" (credential "stake.skey")]
              ++ optionals (cfg.inputsPerTx != null) ["--inputs-per-tx" (toString cfg.inputsPerTx)]
              ++ optionals (cfg.color != null) ["--color" cfg.color]
              ++ cfg.extraArgs
            );

            DynamicUser = true;

            LoadCredential =
              ["funds.skey:${cfg.signingKeyFile}"]
              ++ optionals (cfg.stakingKeyFile != null) ["stake.skey:${cfg.stakingKeyFile}"];

            # Not on-failure: a drained fund set ends the submission client
            # cleanly and exits 0, so on-failure would leave the rest of the
            # window silently idle. An explicit stop never restarts, and the
            # SIGTERM from both the stop timer and the runtime cap is
            # excluded below, so the window edges still hold.
            Restart = "always";

            # A restart re-queries the chain, whose UTxO the previous
            # incarnation's mempool transactions already spend. Waiting lets
            # those drain, otherwise every submit rejects as
            # AllInputsAreSpent.
            RestartSec = 60;

            RestartPreventExitStatus = "SIGTERM";

            # systemd's disable value is "infinity", not 0, which would
            # terminate the service immediately.
            RuntimeMaxSec =
              if cfg.maxRuntimeSeconds == 0
              then "infinity"
              else cfg.maxRuntimeSeconds;

            # One trace line per submitted transaction would otherwise be
            # dropped by the journald default of 10000 in 30s.
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
    };
  });
}
