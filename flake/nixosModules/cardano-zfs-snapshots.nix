_: {
  # Profile: rolling, crash-consistent ZFS snapshots of a dataset on a timer,
  # pruned to a fixed count — giving a `keep * cadence` point-in-time recovery
  # window. Useful on any cluster for recovering transient on-disk state (e.g.
  # a service's working/volatile data) hours after the fact, by which time the
  # live copy has usually been overwritten.
  #
  # Snapshots are whole-dataset, crash-consistent and cheap copy-on-write.
  #
  # Snapshot recovery:
  #   zfs list -t snapshot -o name,creation -s creation | grep "<dataset>@autosnap"
  #   mkdir -p /mnt/snap && mount -t zfs <dataset>@autosnap-<ts> /mnt/snap
  #   # ...or browse it in-place under <dataset-mountpoint>/.zfs/snapshot/<name>/
  flake.nixosModules.cardano-zfs-snapshots = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.cardano-zfs-snapshots;
    zfs = "${config.boot.zfs.package}/bin/zfs";

    snapshotScript = pkgs.writeShellApplication {
      name = "cardano-zfs-snapshots";
      runtimeInputs = [config.boot.zfs.package pkgs.coreutils pkgs.findutils];
      text = ''
        set -euo pipefail
        dataset=${lib.escapeShellArg cfg.dataset}
        prefix=${lib.escapeShellArg cfg.prefix}
        keep=${toString cfg.keep}

        # No-op cleanly if the dataset isn't present (e.g. before first import).
        if ! ${zfs} list -H -o name "$dataset" >/dev/null 2>&1; then
          echo "cardano-zfs-snapshots: dataset $dataset not found, skipping" >&2
          exit 0
        fi

        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        ${zfs} snapshot "$dataset@$prefix-$stamp"
        echo "cardano-zfs-snapshots: created $dataset@$prefix-$stamp"

        # Prune: keep the newest $keep snapshots with our prefix, destroy older.
        # `-s creation` lists oldest-first; drop the trailing $keep from deletion.
        # Only snapshots with our prefix are considered (other snapshots, incl.
        # any `@blank`/manual baselines, are never touched).
        mapfile -t toPrune < <(
          ${zfs} list -H -t snapshot -o name -s creation \
            | { grep -F "$dataset@$prefix-" || true; } \
            | head -n "-$keep"
        )
        for snap in "''${toPrune[@]}"; do
          echo "cardano-zfs-snapshots: pruning $snap"
          ${zfs} destroy "$snap"
        done
      '';
    };
  in {
    options.services.cardano-zfs-snapshots = {
      dataset = lib.mkOption {
        type = lib.types.str;
        default = "tank/root";
        description = ''
          ZFS dataset to snapshot. Defaults to `tank/root`, the usual
          cardano-parts root dataset (which holds /var/lib and thus most
          service state). If the data you care about isn't its own dataset,
          the whole root is snapshotted — cheap via copy-on-write.
        '';
      };

      prefix = lib.mkOption {
        type = lib.types.str;
        default = "autosnap";
        description = "Snapshot name prefix. Only snapshots with this prefix are pruned by this module.";
      };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "*:0/20";
        description = "systemd `OnCalendar` cadence. Default: every 20 minutes.";
      };

      keep = lib.mkOption {
        type = lib.types.ints.positive;
        default = 72;
        description = ''
          Number of recent prefixed snapshots to retain. With the default
          20-minute cadence, 72 snapshots ≈ a 24 h recovery window.
        '';
      };
    };

    config = {
      systemd.services.cardano-zfs-snapshots = {
        description = "Rolling ZFS snapshot of ${cfg.dataset} for point-in-time recovery";
        # Only meaningful once the pool is mounted.
        after = ["zfs-mount.service"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe snapshotScript;
        };
      };

      systemd.timers.cardano-zfs-snapshots = {
        description = "Schedule rolling ZFS snapshots for point-in-time recovery";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.onCalendar;
          Persistent = true;
          RandomizedDelaySec = "30s";
        };
      };
    };
  };
}
