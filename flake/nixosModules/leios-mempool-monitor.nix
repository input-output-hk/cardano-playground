{moduleWithSystem, ...}: {
  # Persist a mempool snapshot series for later analysis.
  #
  # Importing this module is the enablement: `enable` defaults true, so a host
  # only names it in imports. There is nothing per host to wire, no secret and
  # no key, so the usual service/profile split would buy nothing.
  #
  # mempool-monitor already loops on --interval, and --tsv appends one row per
  # snapshot, writing the header only for a fresh file, so a restart appends
  # cleanly. That makes a long running service the right shape rather than a
  # timer taking snapshots: a timer would pay the connect cost every tick and
  # leave a file per run to stitch together.
  #
  # Under systemd stdout is not a terminal, which the tool detects itself
  # (hIsTerminalDevice) and switches from the repainting pane to one line per
  # snapshot, so the journal gets readable text while the tsv gets the data.
  flake.nixosModules.leios-mempool-monitor = moduleWithSystem ({inputs'}: {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (lib) mkIf mkOption types;
    inherit (config.cardano-parts.perNode.lib) cardanoLib;

    serviceName = "leios-mempool-monitor";
    cfg = config.services.leios-mempool-monitor;

    groupCfg = config.cardano-parts.cluster.group;
    environment = cardanoLib.environments.${groupCfg.meta.environmentName};

    # One node per host, matching cardano-tx-firehose.
    nodeUnit = "cardano-node.service";

    # Makes the node socket group readable, and is WantedBy the node. Pulled in
    # rather than required, since a node already running from before this was
    # deployed never picked up that want.
    socketUnit = "cardano-node-socket-share.service";
  in {
    options.services.${serviceName} = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to run the mempool snapshot service. Defaults true so that
          importing the module is the enablement.
        '';
      };

      # Same pin as the node, as with the generators: the observer and the node
      # it reads should move together.
      package = lib.mkPackageOption inputs'.cardano-node-leios.packages "mempool-monitor-static" {};

      socketPath = mkOption {
        type = types.str;
        default = config.services.cardano-node.socketPath 0;
        defaultText = lib.literalExpression "config.services.cardano-node.socketPath 0";
        description = "Node socket to read the mempool from.";
      };

      testnetMagic = mkOption {
        type = types.int;
        default = environment.peerSnapshot.NetworkMagic;
        defaultText = lib.literalExpression "the group environment's NetworkMagic";
        description = ''
          Network magic of the chain being observed. Taken from the group's
          environment rather than a literal, so this follows a host to another
          network without edit.
        '';
      };

      interval = mkOption {
        type = types.int;
        default = 60;
        description = ''
          Seconds between snapshots.

          A drain is one round trip per transaction, but the mempool is capped
          at twice maxBlockBodySize, so at leios transaction sizes it holds a
          few hundred transactions and a drain costs tens of milliseconds.
          Minutely therefore spends well under 1% of the time draining while
          still resolving the fill and drain edges of the one hour duty cycle.

          Watch the drainSecs column. The interval is the period between
          snapshot starts, not a gap after each one, so a drain that overruns
          it degrades to draining continuously rather than stretching the
          cadence.

          At this default a row is roughly 64 bytes, about 0.09 MB per host
          per day.
        '';
      };

      label = mkOption {
        type = types.str;
        default = config.networking.hostName;
        defaultText = lib.literalExpression "config.networking.hostName";
        description = "Name for this node in the output.";
      };

      tsvFile = mkOption {
        type = types.str;
        default = "/var/lib/${serviceName}/mempool.tsv";
        description = ''
          Append only snapshot series, one row per snapshot. This is the
          analysis artifact to collect at the end of a load test.
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra arguments, eg --own-color.";
      };
    };

    config = mkIf cfg.enable {
      services.cardano-node.shareNodeSocket = lib.mkDefault true;

      systemd.services.${serviceName} = {
        wantedBy = ["multi-user.target"];

        # wants rather than requisite: a node restart should not stop the
        # observer, and leios hosts restart the node on a 12h timer. The socket
        # also only appears after chunk validation and ledger replay, which is
        # minutes after an artifact restore, so wait for it before starting.
        wants = [nodeUnit socketUnit];
        after = [nodeUnit socketUnit];

        # Runs as the same user/groups as the monitor. After= only orders
        # service startup; it does not wait for the socket or its permissions.
        # TimeoutStartSec bounds this wait. A connection race after the check
        # is still handled by Restart=always.
        preStart = ''
          socket=${lib.escapeShellArg cfg.socketPath}
          if [[ ! -S "$socket" || ! -w "$socket" ]]; then
            echo "Waiting for writable node socket: $socket"
            until [[ -S "$socket" && -w "$socket" ]]; do
              ${pkgs.coreutils}/bin/sleep 1
            done
          fi
        '';

        serviceConfig = {
          TimeoutStartSec = "15min";
          SupplementaryGroups = lib.singleton config.services.cardano-node.socketGroup;

          ExecStart = toString (
            [
              (lib.getExe' cfg.package "mempool-monitor")
              "--socket-path"
              cfg.socketPath
              "--testnet-magic"
              (toString cfg.testnetMagic)
              "--label"
              cfg.label
              "--interval"
              (toString cfg.interval)
              "--tsv"
              cfg.tsvFile
            ]
            ++ cfg.extraArgs
          );

          DynamicUser = true;
          StateDirectory = serviceName;
          StateDirectoryMode = "0755";

          Restart = "always";
          RestartSec = 30;

          # The node socket is unavailable for minutes after a restore, so allow
          # a long retry run rather than tripping the default rate limit.
          startLimitBurst = 20;
          startLimitIntervalSec = 3600;
        };
      };
    };
  });
}
