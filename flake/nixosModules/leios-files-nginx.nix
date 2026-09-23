_: {
  flake.nixosModules.leios-files-nginx = {
    config,
    lib,
    name,
    pkgs,
    ...
  }: let
    inherit (groupCfg.meta) domain;
    groupCfg = config.cardano-parts.cluster.group;
    cfg = config.services.leios-files-nginx;
    csCfg = cfg.chainSnapshot;
    zoneName = "leiosFilesArtifacts";
    indexDir = "/var/lib/leios-files-nginx";
    zfs = "${config.boot.zfs.package}/bin/zfs";

    # Create + permission the served artifacts dir. A oneshot (not tmpfiles)
    # because servedDir typically lives on a late-mounted volume (e.g.
    # /ephemeral instance store): the unit is ordered after that mount via
    # RequiresMountsFor + setupAfter, so the dir is made on the real fs, not
    # shadowed under the mountpoint.
    setupScript = pkgs.writeShellApplication {
      name = "leios-files-nginx-setup";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        set -euo pipefail
        mkdir -p ${lib.escapeShellArg cfg.servedDir}
        # 0755: world-traversable so nginx (any user) can read the 0644 artifacts.
        chmod 0755 ${lib.escapeShellArg cfg.servedDir}
      '';
    };

    # Bash array literal of chain members (relative to the node data dir inside
    # the snapshot). With no tarPaths the whole chain subdir is included; with
    # tarPaths, only those subdirectories of it.
    chainMembersArr =
      if csCfg.tarPaths == []
      then ''( "$chainName" )''
      else "( " + lib.concatMapStringsSep " " (p: ''"$chainName/${p}"'') csCfg.tarPaths + " )";

    # Publishes one compressed tarball of cardano-node state into servedDir,
    # assembled from two filesystems because w38a splits the node database:
    #
    #   sourcePath          (ZFS)          immutable/ + leios.imm.db
    #   volatileSourcePath  (instance store) volatile/ ledger/ gsm/ + leios.vol.db
    #
    # The immutable side is read from the newest rolling ZFS snapshot that the
    # cardano-parts `profile-zfs-snapshots` module produces (<dataset>@<prefix>-*),
    # atomic and crash-consistent without stopping the node. The volatile side is
    # off-pool so no snapshot covers it, and is staged live instead:
    #
    #   - the newest ledger snapshot dir that contains `meta`, which consensus
    #     writes last, so a dir having it is fully written and safe to copy. This
    #     is what saves a consumer a full ledger replay. volatile/ and gsm/ are
    #     not shipped; the node rebuilds them.
    #   - both leios SQLite DBs, via SQLite's online backup (`.backup`), which
    #     yields a consistent copy of a live DB without a node stop. Only files
    #     matching `leiosDbGlob` whose header is `SQLite format 3` are backed up,
    #     so live WAL/SHM companions and the published artifact itself are never
    #     backup sources. leios.imm.db is excluded from the ZFS side of the tar
    #     and taken this way too, so both DBs get the same treatment.
    #
    # Each backed-up DB is shipped with 0-byte `-wal`/`-shm` members so extraction
    # truncates any stale journal files in the destination (see the staging loop).
    # The artifact is named `leios.*` (served + indexed) and extracts into a
    # cardano-node data dir as a single `<artifactDirName>/` tree (default `db/`):
    # the chain dir is renamed in-archive from its on-disk basename (e.g.
    # `db-leios`) and the staged files are placed inside it. Runs as root.
    snapshotPublishScript = pkgs.writeShellApplication {
      name = "leios-chain-snapshot-publish";
      runtimeInputs = [
        config.boot.zfs.package
        config.services.cardano-node.package
        pkgs.coreutils
        pkgs.findutils
        pkgs.gawk
        pkgs.gnutar
        pkgs.zstd
        pkgs.gzip
        pkgs.xz
        pkgs.sqlite
        pkgs.jq
        pkgs.util-linux # ionice
      ];
      text = ''
        set -euo pipefail

        dataset=${lib.escapeShellArg csCfg.dataset}
        prefix=${lib.escapeShellArg csCfg.snapshotPrefix}
        src=${lib.escapeShellArg csCfg.sourcePath}
        servedDir=${lib.escapeShellArg cfg.servedDir}

        # The node build that produced this state. State is not portable across
        # incompatible node revs, so a consumer needs to pair an artifact with
        # the node it is about to run. Read from the configured package at
        # publish time so it cannot drift from what is deployed.
        nodeVer=$(cardano-node --version 2>/dev/null || true)
        nodeVersion=$(printf '%s\n' "$nodeVer" | awk 'NR == 1 {print $2; exit}')
        nodeRev=$(printf '%s\n' "$nodeVer" | awk '/git rev/ {print $3; exit}')
        [ -n "$nodeVersion" ] || nodeVersion=unknown
        [ -n "$nodeRev" ] || nodeRev=unknown

        # Stamp every archive member as root (uid/gid 0). These tarballs are a
        # public bootstrap artifact: third-party consumers don't have our
        # `cardano-node` system user, and its uid/gid is dynamically allocated
        # (isSystemUser) so it isn't even stable across our own hosts. uid/gid 0
        # is the one ownership every system recognizes, so it extracts cleanly
        # everywhere. tar otherwise preserves each file's on-disk ownership
        # (e.g. cardano-node for the chain files) regardless of the publisher
        # running as root, so we set 0 explicitly. Our own cardano-parts
        # consumers re-own the data dir on extract (tmpfiles/service context),
        # so losing the node ownership here costs them nothing. To land
        # node-owned files directly, extract as the node user instead of root:
        # non-root tar ignores the archived (root) ownership and uses the
        # extracting user, so the files come out cardano-node:cardano-node, e.g.
        #   sudo -u cardano-node -- tar -C /var/lib/cardano-node -xpf leios.tar.zst
        # (-p preserves the archived modes; the dest must be writable by the node user).
        ownerArgs=(--owner=0 --group=0)

        # Newest snapshot profile-zfs-snapshots generates: exactly
        # <dataset>@<prefix>-<UTC stamp> on <dataset> (-d 1 excludes child
        # datasets). Exact-match so a manual/one-off snapshot that merely
        # shares the prefix is never picked. Held ones are fine to read.
        snap=$(${zfs} list -H -t snapshot -o name -s creation -d 1 "$dataset" 2>/dev/null \
                 | { grep -E "@$prefix-[0-9]{8}T[0-9]{6}Z$" || true; } | tail -n1)
        if [ -z "$snap" ]; then
          echo "leios-chain-snapshot: no $dataset@$prefix-* snapshot found (is zfs-snapshots running here?), skipping" >&2
          exit 0
        fi
        snapname=''${snap#*@}

        # Resolve where the dataset is mounted so we can browse its snapshot in
        # place via the .zfs control dir (no mount/umount). findmnt works for
        # both ZFS-property and legacy/fstab mounts (where the `mountpoint`
        # property is "legacy", not a path); fall back to the property only if
        # findmnt can't resolve it.
        mp=$(findmnt -n -f -o TARGET --source "$dataset" 2>/dev/null | head -n1)
        if [ -z "$mp" ]; then
          mpprop=$(${zfs} get -H -o value mountpoint "$dataset" 2>/dev/null || true)
          case "$mpprop" in
            /*) mp=$mpprop ;;
          esac
        fi
        if [ -z "$mp" ]; then
          echo "leios-chain-snapshot: could not resolve a mount point for dataset $dataset (not mounted?), skipping" >&2
          exit 0
        fi
        mp=''${mp%/}
        rel=''${src#"$mp"}; rel=''${rel#/}
        snapsrc="$mp/.zfs/snapshot/$snapname/$rel"
        if [ ! -d "$snapsrc" ]; then
          echo "leios-chain-snapshot: $snapsrc not present in $snap (check chainSnapshot.dataset/sourcePath), skipping" >&2
          exit 0
        fi

        # Tar the chain relative to the node data dir (parent of the chain subdir)
        # so each artifact extracts into a cardano-node data dir.
        snapParent=$(dirname "$snapsrc")
        chainName=$(basename "$src")
        chainmembers=${chainMembersArr}

        # In-archive name for the node state dir: the on-disk chain dir (e.g.
        # `db-leios`) is renamed to this in every artifact so consumers extract
        # the directory name most node setups already use (default `db`). Two
        # transforms cover the bare dir member and any `tarPaths` submembers.
        artDir=${lib.escapeShellArg csCfg.artifactDirName}
        xformArgs=(--transform "s,^$chainName/,$artDir/," --transform "s,^$chainName$,$artDir,")

        mkdir -p "$servedDir"
        created=$(${zfs} get -H -o value creation "$snap")
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        stagefiles=()
        stage=$(mktemp -d "$servedDir/.stage.XXXXXX")
        trap 'rm -rf "$stage"' EXIT
        mkdir -p "$stage/$artDir"

        # The volatile-side partition lives on fast storage outside the ZFS pool
        # (w38a splits the node db: immutable/ + leios.imm.db on `sourcePath`,
        # volatile/ ledger/ gsm/ + leios.vol.db on `volatileSourcePath`), so the
        # ZFS snapshot cannot see it. Stage the newest *complete* ledger snapshot
        # live: consensus writes a snapshot dir as state, then tables, then `meta`
        # last, so a dir containing `meta` is fully written and safe to copy.
        volSrc=${lib.escapeShellArg csCfg.volatileSourcePath}
        ledgerDir=${lib.escapeShellArg csCfg.ledgerDirName}
        if [ -d "$volSrc/$ledgerDir" ]; then
          # Snapshot dirs are named <slot>[_suffix]; sort numerically on the
          # leading slot and take the highest.
          newest=$(find "$volSrc/$ledgerDir" -mindepth 2 -maxdepth 2 -type f -name meta -printf '%h\n' 2>/dev/null \
                     | while read -r d; do printf '%s\t%s\n' "$(basename "$d")" "$d"; done \
                     | sort -n -k1,1 | tail -n1 | cut -f2)
          if [ -n "$newest" ]; then
            mkdir -p "$stage/$artDir/$ledgerDir"
            nice -n 19 ionice -c3 cp -a "$newest" "$stage/$artDir/$ledgerDir/"
            echo "leios-chain-snapshot: staged ledger snapshot $(basename "$newest")"
          else
            echo "leios-chain-snapshot: WARNING no complete ledger snapshot in $volSrc/$ledgerDir; artifact will force a ledger replay" >&2
          fi
        else
          echo "leios-chain-snapshot: WARNING $volSrc/$ledgerDir absent; artifact will force a ledger replay" >&2
        fi

        # The remaining volatile-side dirs, copied wholesale. Before the split
        # these sat on the ZFS pool and were picked up by the chain tar, so
        # omitting them here would silently drop them from the artifact. They
        # are small, and shipping volatile/ means a restored node resumes near
        # the tip instead of refetching the last k blocks. A live copy can catch
        # a partial block write, which the VolatileDB tolerates: it checksums
        # each block on open and discards any that fail.
        # shellcheck disable=SC2043 # volatileStagePaths may hold a single entry
        for d in ${lib.concatStringsSep " " (map lib.escapeShellArg csCfg.volatileStagePaths)}; do
          if [ -d "$volSrc/$d" ]; then
            nice -n 19 ionice -c3 cp -a "$volSrc/$d" "$stage/$artDir/"
            echo "leios-chain-snapshot: staged $d ($(du -sh "$stage/$artDir/$d" | cut -f1))"
          else
            echo "leios-chain-snapshot: $volSrc/$d absent, skipping" >&2
          fi
        done

        # Consistent online copies of the live leios SQLite DBs — no node stop.
        # One DB sits beside each partition, so both source dirs are scanned.
        # Staged under `$artDir/` so their in-archive paths land inside the
        # renamed chain dir (e.g. `db/leios.vol.db`) and the artifact is one tree.
        shopt -s nullglob
        for f in "$src"/${csCfg.leiosDbGlob} "$volSrc"/${csCfg.leiosDbGlob}; do
          [ -f "$f" ] || continue
          # Only genuine SQLite main DBs (skips -wal/-shm and our own artifacts).
          # Compare the 16-byte magic as hex so binary companions don't trip
          # "ignored null byte" warnings from command substitution.
          [ "$(head -c 16 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "53514c69746520666f726d6174203300" ] || continue
          bn=$(basename "$f")
          if nice -n 19 ionice -c3 sqlite3 "$f" ".backup '$stage/$artDir/$bn'" 2>/dev/null; then
            echo "leios-chain-snapshot: online-backed-up $bn"
            # Ship 0-byte -wal/-shm companions alongside each backed-up DB.
            # The .backup output is complete standalone; but if a consumer
            # extracts over a data dir that still has a stale journal from a
            # previous run, SQLite pairs the fresh main file with the old
            # mismatched -wal and fails open with "database disk image is
            # malformed". Extraction of these empty members truncates any
            # such leftovers (SQLite treats empty companions as absent and
            # reinitializes them), so no manual rm is needed on restore.
            : > "$stage/$artDir/$bn-wal"
            : > "$stage/$artDir/$bn-shm"
          else
            echo "leios-chain-snapshot: WARNING sqlite online backup of $bn failed, omitting" >&2
            rm -f "$stage/$artDir/$bn" "$stage/$artDir/$bn-wal" "$stage/$artDir/$bn-shm"
          fi
        done
        shopt -u nullglob
        mapfile -t stagefiles < <(cd "$stage" && find "$artDir" -mindepth 1 -maxdepth 1 | sort)

        # publish <artifact> <tar-args...>  (atomic; world-readable).
        publish() (
          art=$1; shift
          echo "leios-chain-snapshot: building $art from $snap ..."
          tmp=$(mktemp "$servedDir/.$art.XXXXXX")
          trap 'rm -f "$tmp"' EXIT
          # Throttled so publishing doesn't starve the node's IO/CPU.
          nice -n 19 ionice -c3 tar -cf - "''${ownerArgs[@]}" "$@" | ${csCfg.compressor} > "$tmp"
          sum=$(sha256sum "$tmp" | cut -d' ' -f1)
          size=$(stat -c %s "$tmp")
          chmod 0644 "$tmp"
          mv -f "$tmp" "$servedDir/$art"
          trap - EXIT
          printf '%s  %s\n' "$sum" "$art" > "$servedDir/$art.sha256"
          jq -n \
            --arg artifact "$art" \
            --arg sha256 "$sum" \
            --argjson bytes "$size" \
            --arg zfs_snapshot "$snap" \
            --arg snapshot_created "$created" \
            --arg published "$now" \
            --arg node_version "$nodeVersion" \
            --arg node_rev "$nodeRev" \
            '{
              artifact: $artifact,
              sha256: $sha256,
              bytes: $bytes,
              node_version: $node_version,
              node_rev: $node_rev,
              zfs_snapshot: $zfs_snapshot,
              snapshot_created: $snapshot_created,
              published: $published
            }' \
            > "$servedDir/$art.meta.json"
          chmod 0644 "$servedDir/$art.sha256" "$servedDir/$art.meta.json"
          echo "leios-chain-snapshot: published $art ($size bytes, sha256 $sum)"
        )

        # One artifact: the immutable side from the ZFS snapshot, plus everything
        # staged above from the non-ZFS volatile side. leios.imm.db lives inside
        # the snapshotted dir, so exclude it there and take the staged
        # sqlite-backed-up copy instead, which also carries the 0-byte companions.
        # The exclude is anchored to "$chainName/" because tar applies excludes
        # globally across every -C section: an unanchored `leios.*.db` would also
        # drop the staged copies we just made.
        if [ ''${#stagefiles[@]} -gt 0 ]; then
          publish ${lib.escapeShellArg csCfg.artifactName} \
            "''${xformArgs[@]}" --exclude="$chainName/${csCfg.leiosDbGlob}*" \
            -C "$snapParent" "''${chainmembers[@]}" \
            -C "$stage" "''${stagefiles[@]}"
        else
          echo "leios-chain-snapshot: WARNING nothing staged from $volSrc; '${csCfg.artifactName}' will contain the immutable chain only" >&2
          publish ${lib.escapeShellArg csCfg.artifactName} \
            "''${xformArgs[@]}" --exclude="$chainName/${csCfg.leiosDbGlob}*" \
            -C "$snapParent" "''${chainmembers[@]}"
        fi
      '';
    };
  in {
    # Profile to serve cardano-node bootstrap artifacts (leios.* tarballs etc.)
    # over HTTP from a dedicated directory (servedDir), separate from the node's
    # data dir. Only files matching leios.* directly in servedDir are served
    # (no subdir descent). When enableIndex is on (the default), an HTML listing
    # of the served files is rendered at '/'.
    #
    # When chainSnapshot.enable is on, a timer publishes compressed tarball(s)
    # into servedDir: the chain DB cut from the rolling ZFS snapshots that the
    # `profile-zfs-snapshots` module produces, and/or a CONSISTENT online backup
    # of the live leios SQLite DB(s). Choose any of: chain-only, chain+leios.db
    # (full), or leios.db-only — letting nodes bootstrap from a recent snapshot
    # instead of syncing from genesis. Only the consistent published artifacts
    # are served (never the live, mid-write node files).
    options.services.leios-files-nginx = {
      serverName = lib.mkOption {
        type = lib.types.str;
        default = "${name}.${domain}";
        description = ''
          nginx server_name (FQDN) under which the files are served, and
          the ACME TLS cert name when enableAcme is true. Defaults to
          `''${name}.''${domain}` of the machine importing this module,
          where `name` is the colmena node name and `domain` comes from
          `cardano-parts.cluster.group.meta.domain`.
        '';
      };

      serverAliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra FQDN aliases to be added to the ACME TLS cert and nginx virtualHost.";
      };

      servedDir = lib.mkOption {
        type = lib.types.str;
        default = "/ephemeral/nginx-artifacts";
        description = ''
          Dedicated directory nginx serves leios.* files from, and into which
          the chainSnapshot publisher writes its artifacts. Kept separate from
          the cardano-node data dir so only consistent, published artifacts are
          exposed (never live, mid-write node files). Created + permissioned by
          a setup oneshot (see setupAfter).
        '';
      };

      setupAfter = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["ephemeral.mount"];
        description = ''
          Extra systemd units the served-dir setup oneshot should run after
          (and want). `RequiresMountsFor` on servedDir is always added, which
          covers mount-unit volumes (incl. cardano-parts'
          `profile-aws-ec2-ephemeral`, where /ephemeral is the automounted
          `ephemeral.mount`). For that profile, `[ "ephemeral.mount" ]` makes
          the dependency explicit/eager (matching its own
          `ephemeral-post-mount` service). Use this for a volume set up by a
          plain (non-mount-unit) service instead.
        '';
      };

      acmeEmail = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The default contact email to be used for ACME certificate acquisition.";
      };

      acmeProd = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to use the ACME TLS production server for certificate requests (vs the staging server).";
      };

      enableAcme = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to obtain an ACME TLS cert for nginx and force HTTPS.";
      };

      enableIndex = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to expose an HTML index of available leios.* files at
          the virtualHost root. A small oneshot service regenerates the
          index page by listing leios.* files in servedDir on a timer; the
          result is served by nginx at `/`. Set false to revert `/` to a
          strict 404.
        '';
      };

      indexRefreshInterval = lib.mkOption {
        type = lib.types.str;
        default = "1min";
        description = ''
          systemd OnUnitActiveSec interval for regenerating the index
          page. Snapshot artifacts change infrequently, so a minute is
          fine for ops UX. Tighten for testing.
        '';
      };

      openFirewallNginx = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to open the firewall TCP ports used by nginx: 80, 443.";
      };

      extraLocations = lib.mkOption {
        type = with lib.types; attrsOf anything;
        default = {};
        description = ''
          Extra nginx 'locations' to merge into the virtualHost. The
          leios-file regex location and the `/` index/deny location are
          added on top.
        '';
      };

      limits = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Apply per-client connection and per-connection bandwidth caps to
            artifact serving. These hosts are often relays whose uplink is
            shared with node duties, so an unbounded multi-GB download fleet
            can starve block/header serving. Caps bound that blast radius.
            Tune to the host's uplink.
          '';
        };

        connPerIp = lib.mkOption {
          type = lib.types.ints.positive;
          default = 4;
          description = ''
            Max concurrent connections to the artifact location per client IP
            (nginx `limit_conn`). Allows a few parallel/resumed downloads while
            stopping one client from opening hundreds.
          '';
        };

        rate = lib.mkOption {
          type = lib.types.str;
          default = "25m";
          description = ''
            Per-connection bandwidth cap (nginx `limit_rate`, e.g. "25m" =
            25 MB/s). Combined with `connPerIp` this bounds per-IP throughput
            (rate * connPerIp). Set to "0" to disable the bandwidth cap and
            rely on `connPerIp` alone.
          '';
        };

        rateAfter = lib.mkOption {
          type = lib.types.str;
          default = "16m";
          description = ''
            Serve the first N bytes of each response unthrottled before the
            `rate` cap kicks in (nginx `limit_rate_after`). Keeps the tiny
            `.sha256`/`.meta.json` and the start of tarballs fast. Ignored when
            `rate` is "0".
          '';
        };
      };

      chainSnapshot = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether to periodically publish a compressed tarball of cardano-node
            state into servedDir. The immutable chain is cut from the newest
            rolling ZFS snapshot named `<dataset>@<snapshotPrefix>-*` (as produced
            by the `profile-zfs-snapshots` module); the newest complete ledger
            snapshot and both leios SQLite DBs are staged live from
            `volatileSourcePath`, which is off-pool. All are consistent without
            stopping the node. When enabled, `sourcePath` and
            `volatileSourcePath` must be set.
          '';
        };

        sourcePath = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/cardano-node/db-leios";
          example = "/var/lib/cardano-node/db-leios";
          description = ''
            Absolute path of the chain DB directory on the live filesystem, on
            the ZFS `dataset`. Each artifact tars the chain relative to this
            directory's parent; in-archive the directory is renamed to
            `artifactDirName` (default `db`), regardless of its on-disk name.
          '';
        };

        artifactDirName = lib.mkOption {
          type = lib.types.str;
          default = "db";
          description = ''
            Directory name the node state extracts into, inside every artifact.
            The chain DB dir is renamed in-archive from its on-disk basename
            (e.g. `db-leios`) to this name, and the leios SQLite DB(s) are
            placed inside it (e.g. `db/leios.db`) for the `full` and `leiosDb`
            artifacts, so consumers unpack a single directory tree matching
            the common cardano-node database-directory default (`db`).
          '';
        };

        dataset = lib.mkOption {
          type = lib.types.str;
          default = "tank/root";
          description = ''
            ZFS dataset whose rolling snapshots provide the chain DB. Set to
            match `services.zfs-snapshots.dataset`, and to be the
            dataset that actually holds `sourcePath`.
          '';
        };

        snapshotPrefix = lib.mkOption {
          type = lib.types.str;
          default = "autosnap";
          description = "Snapshot name prefix to consume. Set to match `services.zfs-snapshots.prefix`.";
        };

        tarPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = ["immutable" "ledger"];
          description = ''
            Subdirectories of `sourcePath` to include, relative to it. Empty
            (default) includes all of it, which under the w38a split layout is
            `immutable/` plus `leios.imm.db`. The latter is excluded from the
            ZFS side regardless and shipped as a sqlite online backup instead.
          '';
        };

        volatileSourcePath = lib.mkOption {
          type = lib.types.str;
          default = "/ephemeral/cardano-node/db-leios";
          example = "/ephemeral/cardano-node/db-leios";
          description = ''
            Absolute path of the node's volatile database directory, matching
            `services.cardano-node.volatileDatabasePath`. Holds `volatile/`,
            `ledger/`, `gsm/` and `leios.vol.db`. This is deliberately NOT on
            the ZFS `dataset`, so its contents cannot come from the snapshot and
            are staged live at publish time instead.
          '';
        };

        volatileStagePaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["volatile" "gsm"];
          description = ''
            Subdirectories of `volatileSourcePath` copied wholesale into the
            artifact, alongside the ledger snapshot handled by `ledgerDirName`.
            Before the db split these lived on the ZFS pool and were picked up
            by the chain tar, so leaving them out would silently drop them.
            Shipping `volatile` lets a restored node resume near the tip rather
            than refetching the last k blocks. Set to `[]` to omit them.
          '';
        };

        ledgerDirName = lib.mkOption {
          type = lib.types.str;
          default = "ledger";
          description = ''
            Name of the ledger snapshot directory under `volatileSourcePath`.
            Only the newest complete snapshot is shipped, so a consumer starts
            from it rather than replaying. Completeness is judged by the
            presence of the snapshot's `meta` file, which consensus writes last.
          '';
        };

        leiosDbGlob = lib.mkOption {
          type = lib.types.str;
          default = "leios.*.db";
          description = ''
            Glob of candidate leios DB files, matched in both `sourcePath` and
            `volatileSourcePath`, and also used to exclude them from the ZFS
            side of the tar. The default matches the w38a pair `leios.imm.db`
            and `leios.vol.db` while still requiring a `.db` suffix, so operator
            backup/debris copies beside a live DB (e.g. `leios.db.genesis-bak`)
            are not swept in. Non-SQLite matches (WAL/SHM companions) are also
            skipped by the `SQLite format 3` header check.
          '';
        };

        compressor = lib.mkOption {
          type = lib.types.str;
          default = "zstd -T0";
          description = "Command that `tar` output is piped through to produce each artifact (e.g. `zstd -T0`, `gzip`, `xz -T0`).";
        };

        onCalendar = lib.mkOption {
          type = lib.types.str;
          default = "hourly";
          description = "systemd `OnCalendar` cadence for republishing the artifacts.";
        };

        artifactName = lib.mkOption {
          type = lib.types.str;
          default = "leios.tar.zst";
          description = ''
            Filename of the published artifact (must match `leios.*` to be
            served + indexed). One combined tarball is produced: the immutable
            chain from the ZFS snapshot, the newest complete ledger snapshot,
            and both leios SQLite DBs, so a consumer downloads and unpacks a
            single file into a cardano-node data dir.
          '';
        };
      };
    };

    config = {
      assertions = [
        {
          assertion = !csCfg.enable || csCfg.sourcePath != "";
          message = "services.leios-files-nginx.chainSnapshot.sourcePath must be set when chainSnapshot.enable is true.";
        }
      ];

      services.nginx = {
        enable = true;

        # Sensible production defaults; cheap to enable.
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedTlsSettings = true;
        recommendedProxySettings = false;

        # Shared-memory zone backing the per-IP connection cap on the artifact
        # location (~160k tracked IPs per 10m). Declared at http scope; the
        # `limit_conn` that uses it lives in the artifact location below.
        appendHttpConfig = lib.optionalString cfg.limits.enable ''
          limit_conn_zone $binary_remote_addr zone=${zoneName}:10m;
        '';

        virtualHosts.${cfg.serverName} = {
          inherit (cfg) serverAliases;
          forceSSL = cfg.enableAcme;
          enableACME = cfg.enableAcme;

          locations = lib.mkMerge [
            cfg.extraLocations
            {
              # Match only files named 'leios.<something>' (no slashes →
              # no descent into any subdir, e.g. the staging dir).
              "~ ^/(leios\\.[^/]+)$" = {
                root = cfg.servedDir;
                extraConfig =
                  ''
                    # Artifact URLs are mutable (republished on each snapshot), and
                    # a client must pair an artifact with the *matching* sha256/meta.
                    # `no-cache` forces revalidation on every use, so a stale cached
                    # copy is never paired with a fresh checksum. nginx answers an
                    # unchanged file with 304 (ETag/Last-Modified), so unchanged
                    # multi-GB tarballs are not re-downloaded — only re-validated.
                    add_header Cache-Control "no-cache";

                    # recommendedOptimisation enables open_file_cache http-wide; turn
                    # it off here so a just-swapped artifact is never served from a
                    # cached fd pointing at the old inode. (In-flight downloads always
                    # complete from their open fd regardless; this closes the ~30s
                    # window where a *new* request could pair an old tarball with a
                    # freshly-published sha256/meta.) The index/other paths keep it.
                    open_file_cache off;

                    # Don't reveal nginx version on 404 / error pages.
                    server_tokens off;
                  ''
                  + lib.optionalString cfg.limits.enable (''

                      # Bound artifact-serving impact on the host's uplink.
                      limit_conn ${zoneName} ${toString cfg.limits.connPerIp};
                    ''
                    + lib.optionalString (cfg.limits.rate != "0") ''
                      limit_rate ${cfg.limits.rate};
                      limit_rate_after ${cfg.limits.rateAfter};
                    '');
              };

              # Strict 404 for anything not matched above. When enableIndex is
              # on, the exact-match '= /' location below takes precedence over
              # this for the bare root, but everything else still 404s.
              "/" = {
                return = "404";
              };
            }
            (lib.mkIf cfg.enableIndex {
              # Exact match: only the bare root '/' serves the index.
              # Any other path (e.g. '/foo') still falls to the '/' prefix
              # location above and 404s, so the index dir isn't browsable.
              "= /" = {
                root = indexDir;
                extraConfig = ''
                  try_files /index.html =404;
                  # The listing is regenerated on a timer; never serve it stale.
                  add_header Cache-Control "no-cache";
                '';
              };
            })
          ];
        };
      };

      systemd = lib.mkMerge [
        # Always: create + permission servedDir, after the volume holding it is
        # mounted. nginx/index/publisher are ordered after this.
        {
          services.leios-files-nginx-setup = {
            description = "Create + permission the leios-files-nginx served dir";
            wantedBy = ["multi-user.target"];
            before = ["nginx.service"];
            after = cfg.setupAfter;
            wants = cfg.setupAfter;
            unitConfig.RequiresMountsFor = cfg.servedDir;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe setupScript;
            };
          };
        }

        # Index dir owned by nginx so the regen service (running as nginx)
        # can write to it and nginx itself can read it.
        (lib.mkIf cfg.enableIndex {
          tmpfiles.rules = [
            "d ${indexDir} 0755 nginx nginx -"
          ];

          services.leios-files-nginx-index = {
            description = "Regenerate leios.* file index page";
            wantedBy = ["multi-user.target"];
            after = ["nginx.service" "leios-files-nginx-setup.service"];
            requires = ["leios-files-nginx-setup.service"];
            path = [pkgs.coreutils];
            serviceConfig = {
              Type = "oneshot";
              User = "nginx";
              Group = "nginx";
            };
            script = ''
              target=${indexDir}/index.html
              tmp=$(mktemp ${indexDir}/index.html.XXXXXX)
              trap 'rm -f "$tmp"' EXIT

              {
                printf '%s\n' '<!doctype html>'
                printf '%s\n' '<html><head><meta charset="utf-8">'
                printf '<title>leios files on %s</title>\n' '${cfg.serverName}'
                printf '%s\n' '<style>'
                printf '%s\n' 'body{font-family:sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem}'
                printf '%s\n' 'table{border-collapse:collapse;width:100%}'
                printf '%s\n' 'th,td{padding:.4rem .8rem;border-bottom:1px solid #ddd;text-align:left}'
                printf '%s\n' 'th{background:#f4f4f4}'
                printf '%s\n' 'td.size{text-align:right;font-family:monospace}'
                printf '%s\n' 'a{color:#0a58ca;text-decoration:none}a:hover{text-decoration:underline}'
                printf '%s\n' '.meta{color:#666;font-size:.85em;margin-top:1.5rem}'
                printf '%s\n' '</style></head><body>'
                printf '<h1>leios files on %s</h1>\n' '${cfg.serverName}'
                printf '%s\n' '<table>'
                printf '%s\n' '<thead><tr><th>file</th><th>size (bytes)</th><th>modified (UTC)</th></tr></thead>'
                printf '%s\n' '<tbody>'

                count=0
                for f in ${cfg.servedDir}/leios.*; do
                  [ -f "$f" ] || continue
                  fname=$(basename "$f")
                  fsize=$(stat -c %s "$f")
                  fmtime=$(date -u -d "@$(stat -c %Y "$f")" '+%Y-%m-%d %H:%M:%S')
                  printf '<tr><td><a href="/%s">%s</a></td><td class="size">%s</td><td>%s</td></tr>\n' \
                    "$fname" "$fname" "$fsize" "$fmtime"
                  count=$((count + 1))
                done

                printf '%s\n' '</tbody></table>'
                if [ "$count" -eq 0 ]; then
                  printf '%s\n' '<p><em>No leios.* files present in '"${cfg.servedDir}"' yet.</em></p>'
                fi
                printf '<p class="meta">Index regenerated %s.</p>\n' "$(date -u +'%Y-%m-%d %H:%M:%SZ')"
                printf '%s\n' '</body></html>'
              } > "$tmp"

              chmod 0644 "$tmp"
              mv -f "$tmp" "$target"
            '';
          };

          timers.leios-files-nginx-index = {
            description = "Periodic regeneration of leios.* file index page";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnBootSec = "30s";
              OnUnitActiveSec = cfg.indexRefreshInterval;
              Unit = "leios-files-nginx-index.service";
            };
          };
        })

        # Periodic chain/state tarball publisher. Runs as root (reads the node
        # DB in the snapshot, runs sqlite online backups, writes servedDir).
        (lib.mkIf csCfg.enable {
          services.leios-chain-snapshot = {
            description = "Publish cardano-node state tarball(s) from the latest ZFS snapshot";
            after = ["zfs-mount.service" "leios-files-nginx-setup.service"];
            requires = ["leios-files-nginx-setup.service"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe snapshotPublishScript;
            };
          };

          timers.leios-chain-snapshot = {
            description = "Periodic cardano-node state tarball publish";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnCalendar = csCfg.onCalendar;
              Persistent = true;
              RandomizedDelaySec = "2min";
              Unit = "leios-chain-snapshot.service";
            };
          };
        })
      ];

      security.acme = lib.mkIf cfg.enableAcme {
        acceptTerms = true;
        defaults = {
          email = cfg.acmeEmail;
          server =
            if cfg.acmeProd
            then "https://acme-v02.api.letsencrypt.org/directory"
            else "https://acme-staging-v02.api.letsencrypt.org/directory";
        };
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewallNginx [80 443];
    };
  };
}
