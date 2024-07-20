flake: let
  inherit (flake.config.flake.cardano-parts.cluster.infra.aws) domain;
in {
  flake.nixosModules.cardano-ipfs = {
    config,
    pkgs,
    name,
    lib,
    ...
  }: let
    inherit (lib) mkIf mkMerge mkOption;
    inherit (lib.types) bool ints port;
    inherit (groupCfg) groupName groupFlake;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;

    cfg = config.services.cardano-ipfs;
  in {
    options.services.cardano-ipfs = {
      kuboApiPort = mkOption {
        type = port;
        default = 5001;
        description = "The default kubo ipfs api port.";
      };

      kuboGatewayPort = mkOption {
        type = port;
        default = 8888;
        description = "The default kubo ipfs gateway port.";
      };

      kuboSwarmPort = mkOption {
        type = port;
        default = 4001;
        description = "The default kubo ipfs swarm port used by tcp and udp.";
      };

      maxUploadSizeMB = mkOption {
        type = ints.positive;
        default = 1;
        description = "The maximum upload size the /api/v0/add endpoint will accept.";
      };

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
      networking.firewall = {
        allowedTCPPorts = [80 443 cfg.kuboSwarmPort];
        allowedUDPPorts = [cfg.kuboSwarmPort];
      };

      services = {
        kubo = {
          enable = true;
          enableGC = true;
          autoMount = true;

          settings = {
            Addresses = {
              API = ["/ip4/127.0.0.1/tcp/${toString cfg.kuboApiPort}"];
              Gateway = "/ip4/127.0.0.1/tcp/${toString cfg.kuboGatewayPort}";
            };

            Datastore.StorageMax = "40GB";

            # Only advertise local node pinned content to the ipfs network
            Reprovider.Strategy = "pinned";
          };
        };

        nginx = mkMerge [
          {
            enable = true;
          }
          (mkIf cfg.primaryNginx {
            eventsConfig = lib.mkForce "worker_connections 8192;";
            appendConfig = lib.mkForce "worker_rlimit_nofile 16384;";
            recommendedGzipSettings = true;
            recommendedOptimisation = true;
            recommendedProxySettings = true;

            commonHttpConfig = lib.mkForce ''
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
              ipfs = {
                serverName = "ipfs.${domain}";

                default = mkIf cfg.primaryNginx true;
                enableACME = true;
                forceSSL = true;

                basicAuthFile = "/run/secrets/ipfs-auth";

                locations = {
                  "/".root = let
                    markdown = builtins.toFile "index.md" ''
                      APIs exposed through this interface:

                      [`/api/v0/add`](https://docs.ipfs.tech/reference/kubo/rpc/#api-v0-add)
                      ```bash
                      # Push a file to ipfs, use the latest CID version and set
                      # the file in the mutable file system (MFS) for easy
                      # future tracking
                      curl -u "$USER:$PASSWORD" -XPOST \
                        -F "file=@$FILENAME" \
                        "https://ipfs.play.dev.cardano.org/api/v0/add?progress=true&cid-version=1&to-files=/$FILENAME"
                      ```


                      [`/api/v0/version`](https://docs.ipfs.tech/reference/kubo/rpc/#api-v0-version)
                      ```bash
                      # Get the kubo ipfs version:
                      curl -u "$USER:$PASSWORD" -XPOST https://ipfs.play.dev.cardano.org/api/v0/version
                      ```
                    '';
                  in
                    pkgs.runCommand "nginx-root-dir" {buildInputs = [pkgs.pandoc];} ''
                      mkdir $out
                      pandoc \
                        --standalone \
                        --metadata title="IPFS API" \
                        -f markdown \
                        -t html5 \
                        -c style.css \
                        -o $out/index.html \
                        ${markdown}
                    '';

                  # TODO: refactor proxyPass as a map of allowed endpoints
                  "/api/v0/add" = {
                    extraConfig = ''
                      # Fixes interrupted uploads with progress=true
                      # Ref: https://github.com/ipfs/kubo/issues/6402#issuecomment-1085266811
                      client_max_body_size ${toString cfg.maxUploadSizeMB}M;
                      proxy_buffering off;
                      proxy_http_version 1.1;
                      proxy_request_buffering off;
                    '';

                    proxyPass = "http://127.0.0.1:${toString cfg.kuboApiPort}";
                  };

                  "/api/v0/version" = {
                    proxyPass = "http://127.0.0.1:${toString cfg.kuboApiPort}";
                  };
                };
              };
            };
          }
        ];
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
        secretName = "ipfs-auth";
        keyName = "${name}-ipfs-auth";
        inherit groupOutPath groupName;
        fileOwner = "nginx";
        fileGroup = "nginx";
      };
    };
  };
}
