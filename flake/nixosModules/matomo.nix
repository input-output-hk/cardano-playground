flake: {
  flake.nixosModules.matomo = {
    name,
    config,
    pkgs,
    ...
  }: let
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
          enable = true;
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

          # This will ensure consistency and point-in-time snapshot backups.
          singleTransaction = true;

          location = "/var/lib/mysql-backup";

          databases = ["matomo"];

          # Scheduled for a low load time:
          #   US East Coast = ~4:00 am
          #   US West Coast = ~1:00 am
          #   Japan = ~6:00 pm
          calendar = "08:00:00";
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
    };
  };
}
