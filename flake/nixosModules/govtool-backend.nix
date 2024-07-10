flake @ {moduleWithSystem, ...}: let
  inherit (flake.config.flake.cardano-parts.cluster.infra.aws) domain;
in {
  flake.nixosModules.govtool-backend = moduleWithSystem ({inputs'}: {
    pkgs,
    lib,
    name,
    config,
    ...
  }: let
    inherit (groupCfg) groupName groupFlake meta;
    inherit (meta) environmentName;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;
  in {
    environment.systemPackages = [inputs'.govtool.packages.backend];

    networking.firewall.allowedTCPPorts = [80 443];

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

    # services.nginx-vhost-exporter.enable = true;

    services = {
      nginx = let
        staticSite = inputs'.govtool.packages.frontend.overrideAttrs (_: _: {
          VITE_BASE_URL = "/api";
        });
      in {
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
          limit_req_zone $binary_remote_addr zone=apiPerIP:100m rate=1r/s;
          limit_req_status 429;
        '';

        virtualHosts = {
          govtool-backend = {
            serverName = "${name}.${domain}";
            serverAliases = ["${environmentName}-govtool.${domain}" "${environmentName}-explorer.${domain}" "${environmentName}-smash.${domain}"];

            default = true;
            enableACME = true;
            forceSSL = true;

            locations = {
              "/" = {
                root = "${staticSite}/";
                index = "index.html";
                extraConfig = ''
                  try_files $uri $uri /index.html;
                '';
              };
              "/swagger-ui/" = {
                proxyPass = "http://127.0.0.1:9999";
              };
              "/swagger.json" = {
                proxyPass = "http://127.0.0.1:9999";
              };
              "/api/".proxyPass = "http://127.0.0.1:9999/";
            };
          };
        };
      };

      # For debugging govtool failures:
      # postgresql.settings = {
      #   log_connections = true;
      #   log_statement = "all";
      #   log_disconnections = true;
      # };
    };

    systemd.services = {
      govtool-backend = {
        wantedBy = ["multi-user.target"];
        after = ["network-online.target" "postgresql.service"];
        startLimitIntervalSec = 0;
        serviceConfig = {
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "govtool-backend";
            runtimeInputs = [inputs'.govtool.packages.backend];
            text = "vva-be -c /run/secrets/govtool-backend-cfg.json start-app";
          });
          Restart = "always";
          RestartSec = "30s";
        };
      };

      nginx.serviceConfig = {
        LimitNOFILE = 65535;
        LogNamespace = "nginx";
      };
    };

    users = {
      groups.govtool-backend = {};

      users.govtool-backend = {
        isSystemUser = true;
        group = "govtool-backend";
      };
    };

    sops.secrets = mkSopsSecret {
      secretName = "govtool-backend-cfg.json";
      keyName = "${name}-govtool-backend.json";
      inherit groupOutPath groupName;
      fileOwner = "govtool-backend";
      fileGroup = "govtool-backend";
      restartUnits = ["govtool-backend.service"];
    };
  });
}
