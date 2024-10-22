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
    inherit (lib) mkForce mkIf mkMerge mkOption;
    inherit (lib.types) bool;
    inherit (groupCfg) groupName groupFlake meta;
    inherit (meta) environmentName;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;

    cfg = config.services.govtool-backend;
  in {
    options.services.govtool-backend = {
      primaryNginx = mkOption {
        type = bool;
        default = false;
        description = ''
          Whether this module is the primary or only nginx dependent module.

          If not, set this flag false to avoid duplication of nginx boilerplate.
        '';
      };
    };
    config = {
      environment.systemPackages = [(inputs'.govtool.packages.backend.override {returnShellEnv = false;})];

      networking.firewall.allowedTCPPorts = [80 443];

      # services.nginx-vhost-exporter.enable = true;

      services = {
        nginx = let
          staticSite = inputs'.govtool.packages.frontend.overrideAttrs (_: _: {
            VITE_BASE_URL = "/api";
          });
        in
          mkMerge [
            {
              enable = true;
            }
            (mkIf cfg.primaryNginx {
              eventsConfig = mkForce "worker_connections 8192;";
              appendConfig = mkForce "worker_rlimit_nofile 16384;";
              recommendedGzipSettings = true;
              recommendedOptimisation = true;
              recommendedProxySettings = true;

              commonHttpConfig = mkForce ''
                log_format x-fwd '$remote_addr - $remote_user [$time_local] '
                                 '"$scheme://$host" "$request" "$http_accept_language" $status $body_bytes_sent '
                                 '"$http_referer" "$http_user_agent" "$http_x_forwarded_for"';

                access_log syslog:server=unix:/dev/log x-fwd;
                limit_req_zone $binary_remote_addr zone=apiPerIP:100m rate=1r/s;
                limit_req_status 429;
              '';
            })
            {
              virtualHosts = {
                govtool-backend = {
                  default = mkIf cfg.primaryNginx true;
                  serverName = "${environmentName}-govtool.${domain}";

                  enableACME = true;
                  forceSSL = true;

                  locations = {
                    "/" = {
                      root = "${staticSite}/";
                      index = "index.html";
                      extraConfig = ''
                        try_files $uri $uri /index.html;

                        # Nginx doesn't allow static content to handle POST by default
                        error_page 405 =200 $uri;
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
            }
          ];

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
          after = ["postgresql.service"];
          startLimitIntervalSec = 0;
          serviceConfig = {
            ExecStart = lib.getExe (pkgs.writeShellApplication {
              name = "govtool-backend";
              runtimeInputs = [(inputs'.govtool.packages.backend.override {returnShellEnv = false;})];
              text = "vva-be -c /run/secrets/govtool-backend-cfg.json start-app";
            });
            Restart = "always";
            RestartSec = "30s";
          };
        };

        nginx.serviceConfig = mkIf cfg.primaryNginx {
          LimitNOFILE = 65535;
          LogNamespace = "nginx";
        };
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

      sops.secrets = mkSopsSecret {
        secretName = "govtool-backend-cfg.json";
        keyName = "${name}-govtool-backend.json";
        inherit groupOutPath groupName;
        fileOwner = "govtool-backend";
        fileGroup = "govtool-backend";
        restartUnits = ["govtool-backend.service"];
      };

      users = {
        groups.govtool-backend = {};

        users.govtool-backend = {
          isSystemUser = true;
          group = "govtool-backend";
        };
      };
    };
  });
}
