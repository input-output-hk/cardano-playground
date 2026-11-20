flake @ {moduleWithSystem, ...}: {
  flake.nixosModules.leios-firehose-growth = moduleWithSystem ({inputs'}: {
    config,
    lib,
    pkgs,
    name,
    ...
  }: let
    service = "cardano-tx-firehose-growth";
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;
    environment = config.cardano-parts.perNode.lib.cardanoLib.environments.${groupCfg.meta.environmentName};
    firehose = lib.getExe' inputs'.cardano-node-leios-bench.packages.tx-firehose "tx-firehose";
    # run.env may tune FANOUT and TPS. Fanout is part of journal identity:
    # keep it unchanged on resume/drain; TPS may change between invocations.
    run = pkgs.writeShellScript "tx-firehose-growth" ''
      set -euo pipefail
      if [[ ! ''${GROW_BY:-} =~ ^[1-9][0-9]*$ ]]; then
        echo 'Set GROW_BY to net additional UTxOs in /var/lib/tx-firehose-growth-config/run.env' >&2
        exit 1
      fi
      FANOUT="''${FANOUT-200}"
      TPS="''${TPS-7.5}"
      if [[ ! $FANOUT =~ ^[1-9][0-9]{0,4}$ ]] || (( FANOUT > 65534 )); then
        echo 'FANOUT must be an integer from 1 to 65534' >&2
        exit 1
      fi
      if [[ ! $TPS =~ ^[0-9]+([.][0-9]+)?$ || ! $TPS =~ [1-9] ]]; then
        echo 'TPS must be a positive decimal number (for example 7.5 or 50)' >&2
        exit 1
      fi
      exec ${firehose} \
        --socket-path ${lib.escapeShellArg (config.services.cardano-node.socketPath 0)} \
        --testnet-magic ${toString environment.peerSnapshot.NetworkMagic} \
        --signing-key-file "$CREDENTIALS_DIRECTORY/funds.skey" \
        --retained-verification-key-file "$CREDENTIALS_DIRECTORY/retained.vkey" \
        --grow-by "$GROW_BY" \
        --growth-state "$STATE_DIRECTORY/growth.json" \
        --growth-lanes 1000 --fanout "$FANOUT" --retained-lovelace 1000000 \
        --pipeline-depth 64 --growth-poll-seconds 5 --tps "$TPS" \
        "$@" +RTS -N2 -RTS
    '';
    common = {
      # No wantedBy or timers: deployment and boot must not start this experiment.
      requisite = ["cardano-node.service"];
      wants = ["cardano-node-socket-share.service"];
      after = ["cardano-node.service" "cardano-node-socket-share.service"];
      serviceConfig = {
        DynamicUser = true;
        User = service;
        SupplementaryGroups = [config.services.cardano-node.socketGroup];
        StateDirectory = service;
        StateDirectoryMode = "0700";
        EnvironmentFile = "/var/lib/tx-firehose-growth-config/run.env";
        LoadCredential = [
          "funds.skey:/run/secrets/tx-firehose-growth-fund-key"
          "retained.vkey:/run/secrets/tx-firehose-retained-vkey"
        ];
        # Inspect failures, then explicitly resume with the same journal.
        Restart = "no";
        RuntimeMaxSec = "infinity";
        LogRateLimitIntervalSec = 0;
        LogRateLimitBurst = 0;
      };
    };
  in {
    services.cardano-node.shareNodeSocket = lib.mkDefault true;
    sops.secrets =
      opsLib.mkSopsSecret {
        # Separate funding address: preserve the ordinary load generator's
        # funds and dedicate the prefunded lanes to this growth journal.
        secretName = "tx-firehose-growth-fund-key";
        keyName = "${name}-firehose-growth-fund.skey";
        groupOutPath = groupCfg.groupFlake.self.outPath;
        inherit (groupCfg) groupName;
        inherit name;
        fileOwner = "root";
        fileGroup = "root";
        # Key rotation must not start/restart a funded growth experiment.
        restartUnits = [];
      }
      // opsLib.mkSopsSecret {
        secretName = "tx-firehose-retained-vkey";
        keyName = "${name}-firehose-retained.vkey";
        groupOutPath = groupCfg.groupFlake.self.outPath;
        inherit (groupCfg) groupName;
        inherit name;
        fileOwner = "root";
        fileGroup = "root";
        # Only the verification key is deployed. Keep the reclamation signing
        # key encrypted in no-deploy; changing keys must not restart growth.
        restartUnits = [];
      };
    systemd.tmpfiles.rules = ["d /var/lib/tx-firehose-growth-config 0700 root root -"];
    systemd.services = {
      ${service} = lib.recursiveUpdate common {
        description = "Manually started, resumable Leios UTxO growth";
        restartIfChanged = false;
        stopIfChanged = true;
        serviceConfig.ExecStart = run;
      };
      "${service}-drain" = lib.recursiveUpdate common {
        description = "Drain recorded Leios UTxO growth to immutability";
        # Share the original journal and identity arguments; never allocate new
        # batches. Keep GROW_BY and fanout unchanged until draining completes.
        conflicts = ["${service}.service" "${service}-check.service"];
        after = common.after ++ ["${service}.service" "${service}-check.service"];
        restartIfChanged = false;
        stopIfChanged = true;
        serviceConfig.ExecStart = "${run} --growth-drain";
      };
      "${service}-check" = lib.recursiveUpdate common {
        description = "Read-only Leios UTxO growth calibration";
        # Do not query the funding address as a fresh run while growth is active.
        unitConfig.ConditionPathExists = "!/var/lib/${service}/growth.json";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${run} --growth-dry-run";
        };
      };
    };
  });
}
