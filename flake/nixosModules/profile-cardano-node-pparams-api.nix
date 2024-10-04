flake: {
  flake.nixosModules.profile-cardano-node-pparams-api = {
    config,
    pkgs,
    lib,
    name,
    nodeResources,
    ...
  }:
    with builtins;
    with lib; let
      inherit (types) bool float ints listOf oneOf port str;
      inherit (groupCfg.meta) domain;
      inherit (nodeResources) memMiB;

      # inherit (perNodeCfg.meta) cardanoSmashDelistedPools;
      # inherit (perNodeCfg.pkgs) cardano-cli cardano-smash cardano-db-sync-pkgs;

      groupCfg = config.cardano-parts.cluster.group;

      roundFloat = f:
        if f >= (floor f + 0.5)
        then ceil f
        else floor f;

      cfg = config.services.cardano-node-pparams-api;
      cfgNode = config.services.cardano-node;
    in {
      # imports = [flake.config.flake.nixosModules.module-nginx-vhost-exporter];

      options = {
        services.cardano-node-pparams-api = {
          acmeEmail = mkOption {
            type = str;
            default = null;
            description = "The default contact email to be used for ACME certificate aquisition.";
          };

          acmeProd = mkOption {
            type = bool;
            default = true;
            description = "Whether to use the ACME TLS production server for certificate requests.";
          };

          address = mkOption {
            type = str;
            default = "*6";
            description = "The default address for the cardano-node-pparams-api to bind to";
          };

          enableAcme = mkOption {
            type = bool;
            default = true;
            description = "Whether to obtain an ACME TLS cert for serving cardano-node-pparams-api server via nginx.";
          };

          openFirewallNginx = mkOption {
            type = bool;
            default = true;
            description = "Whether to open the firewall TCP ports used by nginx: 80, 443";
          };

          port = mkOption {
            type = port;
            default = 8000;
            description = "The default port for the cardano-node-pparams-api to bind to";
          };

          serverAliases = mkOption {
            type = listOf str;
            default = [];
            description = "Extra FQDN aliases to be added to the ACME TLS cert for serving cardano-node-pparams-api server via nginx.";
          };

          serverName = mkOption {
            type = str;
            default = "${name}.${domain}";
            description = "The default server name for serving cardano-node-pparams-api server via nginx.";
          };

          timeout = mkOption {
            type = ints.positive;
            default = 60;
            description = "The default warp timeout in seconds for the cardano-node-pparams-api server.";
          };

          varnishExporterPort = mkOption {
            type = port;
            default = 9131;
            description = "The port for the varnish metrics exporter to listen on.";
          };

          varnishRamAvailableMiB = mkOption {
            type = oneOf [ints.positive float];
            default = memMiB * 0.10;
            description = "The max amount of RAM to allocate to for cardano-node-pparams-api server varnish object memory backend store.";
          };

          varnishTtlDays = mkOption {
            type = ints.positive;
            default = 30;
            description = ''
              The default number of days for cardano-node-pparams-api server cache object TTL.
              If upstreams serve cache headers, they will take precedence over this value.
            '';
          };
        };
      };

      config = {
        services = {
          varnish = {
            enable = true;
            extraCommandLine = "-t ${toString (cfg.varnishTtlDays * 24 * 3600)} -s malloc,${toString (roundFloat cfg.varnishRamAvailableMiB)}M";
            config = ''
              vcl 4.1;

              import std;

              backend default {
                .host = "127.0.0.1";
                .port = "${toString config.services.cardano-node-pparams-api.port}";
              }

              acl purge {
                "localhost";
                "127.0.0.1";
              }

              sub vcl_recv {
                unset req.http.x-cache;

                # Allow PURGE from localhost
                if (req.method == "PURGE") {
                  if (!std.ip(req.http.X-Real-Ip, "0.0.0.0") ~ purge) {
                    return(synth(405,"Not Allowed"));
                  }

                  # If needed, host can be passed in the curl purge request with -H "Host: $HOST"
                  # along with an allow listed X-Real-Ip header.
                  return(purge);
                }
              }

              sub vcl_hit {
                set req.http.x-cache = "hit";
              }

              sub vcl_miss {
                set req.http.x-cache = "miss";
              }

              sub vcl_pass {
                set req.http.x-cache = "pass";
              }

              sub vcl_pipe {
                set req.http.x-cache = "pipe";
              }

              sub vcl_synth {
                set req.http.x-cache = "synth synth";
                set resp.http.x-cache = req.http.x-cache;
              }

              sub vcl_deliver {
                if (obj.uncacheable) {
                  set req.http.x-cache = req.http.x-cache + " uncacheable";
                }
                else {
                  set req.http.x-cache = req.http.x-cache + " cached";
                }
                set resp.http.x-cache = req.http.x-cache;
              }

              sub vcl_backend_response {
                if (bereq.uncacheable) {
                  return (deliver);
                }
                if (beresp.status == 404) {
                  set beresp.ttl = 1h;
                }
                call vcl_beresp_stale;
                call vcl_beresp_cookie;
                call vcl_beresp_control;
                call vcl_beresp_vary;
                return (deliver);
              }
            '';
          };
        };

        systemd.services = {
          cardano-node-pparams-api = {
            wantedBy = ["multi-user.target"];

            # path = with pkgs; [];

            environment =
              config.environment.variables
              // {
                WARP_BIND_HOST = cfg.address;
                WARP_BIND_PORT = toString cfg.port;
                WARP_TIMEOUT = toString cfg.timeout;
              };

            preStart = ''
              set -uo pipefail
              SOCKET="${cfgNode.socketPath 0}"

              # Wait for the node socket
              while true; do
                [ -S "$SOCKET" ] && sleep 2 && break
                echo "Waiting for cardano node socket at $SOCKET for 2 seconds..."
                sleep 2
              done

              # Wait for the node socket to become group writeable
              while true; do
                [ "$(find "$SOCKET" -type s -perm -g+w)" = "$SOCKET" ] && sleep 2 && break
                echo "Waiting for cardano node socket group write permission at $SOCKET for 2 seconds..."
                sleep 2
              done
            '';

            startLimitIntervalSec = 0;
            serviceConfig = {
              ExecStart = "${flake.inputs.cardano-node-pparams-api.packages.x86_64-linux.cardano-node-pparams-api}/bin/cardano-node-pparams-api";
              User = "cardano-node-pparams-api";
              SupplementaryGroups = "cardano-node";
              StateDirectory = "cardano-node-pparams-api";
              Restart = "always";
              RestartSec = "30s";
            };
          };
        };

        users.users.cardano-node-pparams-api = {
          isSystemUser = true;
          group = "cardano-node-pparams-api";
        };

        users.groups.cardano-node-pparams-api = {};

        networking.firewall.allowedTCPPorts = mkIf cfg.openFirewallNginx [80 443];

        security.acme = mkIf cfg.enableAcme {
          acceptTerms = true;
          defaults = {
            email = cfg.acmeEmail;
            server =
              if cfg.acmeProd
              then "https://acme-v02.api.letsencrypt.org/directory"
              else "https://acme-staging-v02.api.letsencrypt.org/directory";
          };
        };

        # services.nginx-vhost-exporter.enable = true;

        services.nginx = {
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

            # To see all logs, including those already cached by varnish,
            # remove `if=$loggable_varnish` from the following line:
            access_log syslog:server=unix:/dev/log x-fwd if=$loggable_varnish;

            # Allow 1 topology request per 10 seconds.  Logs show clients
            # typically are not requesting this endpoint more than once every
            # 30 seconds and this endpoint resource also typically stays the
            # same for several hours at a time between backend updates.
            limit_req_zone $binary_remote_addr zone=topoRateLimitPerIp:100m rate=6r/m;
            limit_req_status 429;

            map $http_accept_language $lang {
                    default en;
                    ~de de;
                    ~ja ja;
            }

            map $sent_http_x_cache $loggable_varnish {
              "hit cached" 0;
              default 1;
            }
          '';

          virtualHosts = {
            cardano-node-pparams-api = {
              inherit (cfg) serverAliases serverName;

              default = true;
              enableACME = cfg.enableAcme;
              forceSSL = cfg.enableAcme;

              locations = let
                endpoints = [
                  "/tip"
                  "/protocol-parameters"
                ];
              in
                {
                  "/".root = pkgs.runCommand "nginx-root-dir" {} ''mkdir $out; echo -n "Ready" > $out/index.html'';
                }
                // genAttrs endpoints (p: {
                  proxyPass = "http://127.0.0.1:6081${p}";
                });
            };
          };
        };

        systemd.services.nginx.serviceConfig = {
          LimitNOFILE = 65535;
          LogNamespace = "nginx";
        };

        services.prometheus.exporters = {
          varnish = {
            enable = true;
            listenAddress = "127.0.0.1";
            port = cfg.varnishExporterPort;
            group = "varnish";
          };
        };
      };
    };
}
