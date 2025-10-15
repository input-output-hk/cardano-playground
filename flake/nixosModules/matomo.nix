flake: {
  flake.nixosModules.matomo = {
    name,
    config,
    pkgs,
    lib,
    ...
  }: let
    inherit (lib) concatMapStringsSep elem isBool mkBefore mkForce optionalString;
    inherit (flake.config.flake.cardano-parts.cluster.infra.aws) domain;
    hostname = "${name}.${domain}";
  in {
    imports = [flake.self.inputs.cardano-parts.nixosModules.module-nginx-vhost-exporter];

    key = ./matomo.nix;

    config = {
      networking.firewall.allowedTCPPorts = [80 443];

      services = {
        matomo = {
          inherit hostname;
          enable = builtins.trace pkgs.matomo.outPath true;
          nginx = {
            serverName = hostname;
            serverAliases = ["matomo.${domain}"];

            locations = {
              "= /matomo.php" = {
                extraConfig = ''
                  limit_req zone=matomoRateLimitPerIp burst=30 nodelay;
                '';
              };

              "= /piwik.php" = {
                extraConfig = ''
                  limit_req zone=matomoRateLimitPerIp burst=30 nodelay;
                '';
              };
            };
          };
        };

        mysql = {
          enable = true;

          # TODO: Consider pinning this so we don't have unexpected db breakage on machine updates
          package = pkgs.mariadb;

          initialDatabases = [{name = "matomo";}];
          ensureUsers = [
            {
              name = "matomo";
              ensurePermissions = {"matomo.*" = "ALL PRIVILEGES";};
            }
          ];
        };

        mysqlBackup = {
          enable = true;

          # This will be created automatically by services.mysql.ensureUsers.
          user = "mysqlbackup";

          # By default this service will create a matomo.gz which will be
          # overwritten on each backup invocation. While this might be ok for
          # some use cases, we would prefer to maintain at least a few of the
          # most recent daily backups with the systemd script override below.
          location = "/var/lib/mysql-backup";

          # Only back up the matomo db.
          databases = ["matomo"];

          # Scheduled for a low load time:
          #   US East Coast = ~4:00 am
          #   US West Coast = ~1:00 am
          #   Japan = ~6:00 pm
          calendar = "08:00:00";

          # This will ensure consistency and point-in-time snapshot backups.
          singleTransaction = true;

          # Lock the compression alg to gzip as we use it explicitly in the
          # script override below.
          compressionAlg = "gzip";
        };

        nginx = {
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

            limit_req_zone $binary_remote_addr zone=matomoRateLimitPerIp:100m rate=30r/m;
            limit_req_status 429;
          '';
        };

        nginx-vhost-exporter.enable = true;
      };

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

      systemd = let
        cfgBackup = config.services.mysqlBackup;
      in {
        # Allow multiple mysql backups to exist without being overwritten. Aging
        # clean up will be handled by tmpfiles. This code re-uses the upstream
        # service definition with some modifications.
        #
        # The upstream module should have two options added for flexibility:
        # 1) An option backup name suffix.
        # 2) An option declaring the tmpfiles rule, defaulting to what it is currently.
        services.mysql-backup.script = let
          dumpBinary =
            if
              (
                lib.getName config.services.mysql.package
                == lib.getName pkgs.mariadb
                && lib.versionAtLeast config.services.mysql.package.version "11.0.0"
              )
            then "${config.services.mysql.package}/bin/mariadb-dump"
            else "${config.services.mysql.package}/bin/mysqldump";

          compressionAlgs = {
            gzip = rec {
              pkg = pkgs.gzip;
              ext = ".gz";
              minLevel = 1;
              maxLevel = 9;
              cmd = compressionLevelFlag: "${pkg}/bin/gzip -c ${cfgBackup.gzipOptions} ${compressionLevelFlag}";
            };
            xz = rec {
              pkg = pkgs.xz;
              ext = ".xz";
              minLevel = 0;
              maxLevel = 9;
              cmd = compressionLevelFlag: "${pkg}/bin/xz -z -c ${compressionLevelFlag} -";
            };
            zstd = rec {
              pkg = pkgs.zstd;
              ext = ".zst";
              minLevel = 1;
              maxLevel = 19;
              cmd = compressionLevelFlag: "${pkg}/bin/zstd ${compressionLevelFlag} -";
            };
          };

          compressionLevelFlag = optionalString (cfgBackup.compressionLevel != null) (
            "-" + toString cfgBackup.compressionLevel
          );

          selectedAlg = compressionAlgs.${cfgBackup.compressionAlg};
          compressionCmd = selectedAlg.cmd compressionLevelFlag;

          shouldUseSingleTransaction = db:
            if isBool cfgBackup.singleTransaction
            then cfgBackup.singleTransaction
            else elem db cfgBackup.singleTransaction;

          backupDatabaseScript = db: ''
            date=$(date -u "+%Y-%m-%d_%H-%M-%S")
            dest="${cfgBackup.location}/${db}-''${date}${selectedAlg.ext}"
            if ${dumpBinary} ${optionalString (shouldUseSingleTransaction db) "--single-transaction"} ${db} | ${compressionCmd} > $dest.tmp; then
              mv $dest.tmp $dest
              echo "Backed up to $dest"
            else
              echo "Failed to back up to $dest"
              rm -f $dest.tmp
              failed="$failed ${db}"
            fi
          '';
        in
          mkForce ''
            set -o pipefail
            failed=""
            ${concatMapStringsSep "\n" backupDatabaseScript cfgBackup.databases}
            if [ -n "$failed" ]; then
              echo "Backup of database(s) failed:$failed"
              exit 1
            fi
          '';

        # Provide an age expiration as the first and therefore overriding rule
        # for the backup path until the module makes the tmpfiles rule an
        # option.
        tmpfiles.rules = mkBefore [
          "d ${cfgBackup.location} 0700 ${cfgBackup.user} - 7d -"
        ];
      };
    };
  };
}
