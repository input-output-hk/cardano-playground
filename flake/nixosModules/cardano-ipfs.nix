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
    inherit (lib) concatMapStringsSep foldl' mkForce mkIf mkMerge mkOption recursiveUpdate replaceStrings stringLength substring;
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
      environment.systemPackages = [flake.self.packages.x86_64-linux.pinata-go-cli];

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
              ipfs = let
                defaultCfg = ''
                  # Kubo IPFS RPC api will respond with `403 Forbidden` if any
                  # number of headers are present which lead it to believing
                  # access is external.  So remove all headers and then
                  # selectively add back only what is needed to complete the
                  # api call.
                  proxy_pass_request_headers off;
                  proxy_set_header Accept "*/*";
                  proxy_set_header Authorization $http_authorization;
                  proxy_set_header Content-Type $http_content_type;
                  proxy_set_header Content-Length $http_content_length;
                '';

                mkApi = {
                  api,
                  extraCfg ? "",
                }: {
                  ${api} = {
                    extraConfig = defaultCfg + extraCfg;
                    proxyPass = "http://127.0.0.1:${toString cfg.kuboApiPort}";
                  };
                };

                endpoints = [
                  {
                    name = "/api/v0/add";
                    extraHtml = ''
                      ```bash
                      # Push a file with a max size of ${toString cfg.maxUploadSizeMB}MB to IPFS,
                      # use the latest CID version and set the file in the
                      # mutable file system (MFS) for easy future tracking
                      curl -u "$USER:$PASSWORD" -XPOST \
                        -F "file=@$FILENAME" \
                        "https://ipfs.play.dev.cardano.org/api/v0/add?progress=true&cid-version=1&to-files=/$FILENAME"

                      # NOTES:
                      #   * Unless you know what you are doing, avoid
                      #     uploading directories and stick with single files.
                      ```
                    '';
                    tryButton = false;
                    # This api requires non-standard POST calls and will incorrectly write several
                    # post parameters as files with a standard form post.
                    # buttonHtml = api: ''
                    #   <form method="post" action="${api}" enctype="multipart/form-data">
                    #     <label for="file">Filename:</label><br>
                    #     <input type="file" name="file"><br>
                    #     <label for="cid-version">CID version:</label><br>
                    #     <input type="text" name="cid-version" value="1"><br>
                    #     <label for="pin">Pin:</label><br>
                    #     <input type="text" name="pin" value="true"><br>
                    #     <label for="progress">Progress:</label><br>
                    #     <input type="text" name="progress" value="true"><br>
                    #     <label for="to-files">To-files:</label><br>
                    #     <input type="text" name="to-files" value="/$FILENAME"><br>
                    #     <input type="submit" value="Try it">
                    #   </form>
                    # '';
                  }
                  {
                    name = "/api/v0/cat";
                    extraHtml = ''
                      ```bash
                        # The IPFS object should be passed as either `$CID` or `/ipfs/$CID`
                      ```
                    '';
                    # Specifying enctype as `multipart/form-data` causes the API to recognize the post params
                    buttonHtml = api: ''
                      <form method="post" action="${api}" enctype="multipart/form-data">
                        <label for="arg">IPFS object (arg):</label><br>
                        <input type="text" name="arg"><br>
                        <input type="submit" value="Try it">
                      </form>
                    '';
                  }
                  {name = "/api/v0/config/show";}
                  {name = "/api/v0/diag/sys";}
                  {
                    name = "/api/v0/files/ls";
                    extraHtml = ''
                      ```bash
                        # TODO: Requires non-standard POST request for "Try it" button
                      ```
                    '';
                    buttonHtml = api: ''
                      <form method="post" action="${api}" class="inline">
                        <input type="hidden" name="long" value="true">
                        <input type="submit" value="Try it (without hash output)">
                      </form>
                    '';
                  }
                  {
                    name = "/api/v0/files/stat";
                    extraHtml = ''
                      ```bash
                        # The IPFS file should be passed as either `/ipfs/$CID` or `/$FILE_PATH_IN_IPFS_MUTABLE_FS`
                        #
                        # TODO: Requires non-standard POST request for "Try it" button
                      ```
                    '';
                    buttonHtml = api: ''
                      <form method="post" action="${api}">
                        <label for="arg">IPFS path (arg):</label><br>
                        <input type="text" name="arg"><br>
                        <input type="hidden" name="with-local" value="true">
                        <input type="submit" value="Try it (TODO)">
                      </form>
                    '';
                  }
                  {
                    name = "/api/v0/pin/ls";
                    extraHtml = ''
                      ```bash
                        # TODO: Requires non-standard POST request for "Try it" button
                      ```
                    '';
                    buttonHtml = api: ''
                      <form method="post" action="${api}" class="inline">
                        <input type="hidden" name="names" value="true">
                        <input type="submit" value="Try it (without names)">
                      </form>
                    '';
                  }
                  # Most remote pinning services are subscription only
                  # {
                  #   name = "/api/v0/pin/remote/add";
                  #   extraHtml = ''
                  #     ```bash
                  #       # The IPFS file should be passed as either `/ipfs/$CID` or `/$FILE_PATH_IN_IPFS_MUTABLE_FS`
                  #       #
                  #       # TODO: Requires non-standard POST request for "Try it" button
                  #     ```
                  #   '';
                  #   buttonHtml = api: ''
                  #     <form method="post" action="${api}" class="inline">
                  #       <label for="arg">IPFS path (arg):</label><br>
                  #       <input type="text" name="arg"><br>
                  #       <label for="service">Service:</label><br>
                  #       <input type="text" name="service"><br>
                  #       <input type="submit" value="Try it (TODO)">
                  #     </form>
                  #   '';
                  # }
                  # {
                  #   name = "/api/v0/pin/remote/ls";
                  #   extraHtml = ''
                  #     ```bash
                  #       # TODO: Requires non-standard POST request for "Try it" button
                  #     ```
                  #   '';
                  #   buttonHtml = api: ''
                  #     <form method="post" action="${api}" class="inline" enctype="multipart/form-data">
                  #       <label for="service">Service:</label><br>
                  #       <input type="text" name="service"><br>
                  #       <label for="status">Status:</label><br>
                  #       <input type="text" name="status" value="[queued,pinning,pinned,failed]"><br>
                  #       <input type="submit" value="Try it (TODO)">
                  #     </form>
                  #   '';
                  # }
                  # {
                  #   name = "/api/v0/pin/remote/service/ls";
                  #   extraHtml = ''
                  #     ```bash
                  #       # TODO: Requires non-standard POST request for "Try it" button
                  #     ```
                  #   '';
                  #   buttonHtml = api: ''
                  #     <form method="post" action="${api}" class="inline" enctype="multipart/form-data">
                  #       <input type="hidden" name="stat" value="true">
                  #       <input type="submit" value="Try it (without stats)">
                  #     </form>
                  #   '';
                  # }
                  {name = "/api/v0/pin/verify";}
                  {name = "/api/v0/repo/ls";}
                  {name = "/api/v0/repo/verify";}
                  {name = "/api/v0/repo/version";}
                  {
                    name = "/api/v0/routing/findprovs";
                    extraHtml = ''
                      ```bash
                        # The IPFS object should be passed as either `$CID` or `/ipfs/$CID`
                        #
                        # TODO: Requires non-standard POST request for "Try it" button
                      ```
                    '';
                    buttonHtml = api: ''
                      <form method="post" action="${api}" enctype="multipart/form-data">
                        <label for="arg">IPFS object (arg):</label><br>
                        <input type="text" name="arg"><br>
                        <label for="verbose">Verbose:</label><br>
                        <input type="text" name="verbose" value="false"><br>
                        <label for="num-providers">Num-providers:</label><br>
                        <input type="text" name="num-providers" value="20"><br>
                        <input type="submit" value="Try it (TODO)">
                      </form>
                    '';
                  }
                  {name = "/api/v0/stats/bw";}
                  {name = "/api/v0/stats/dht";}
                  {name = "/api/v0/stats/repo";}
                  {name = "/api/v0/version";}
                ];

                proxyPassApis = foldl' (acc: endpoint: recursiveUpdate acc (mkApi {api = endpoint.name;})) {} endpoints;
              in {
                serverName = "ipfs.${domain}";

                default = mkIf cfg.primaryNginx true;
                enableACME = true;
                forceSSL = true;

                basicAuthFile = "/run/secrets/ipfs-auth";

                locations = mkMerge [
                  {
                    "/".root = let
                      githubCss = pkgs.fetchurl {
                        url = "https://gist.githubusercontent.com/forivall/7d5a304a8c3c809f0ba96884a7cf9d7e/raw/62b874d98f72005d18b9b2a05d3be6815959b51b/gh-pandoc.css";
                        hash = "sha256-iOIDiPC3pHCutBPVc6Zz5lQWoBPytj21AElJB7UysJA=";
                      };

                      mkPostButton = api: ''
                        <form method="post" action="${api}" class="inline"><input type="hidden"><input type="submit" value="Try it"></form>
                      '';

                      mkAnchor = api: substring 1 (stringLength api) (replaceStrings ["/"] ["-"] api);

                      mkApiLink = api: "[`${api}`](https://docs.ipfs.tech/reference/kubo/rpc/#${mkAnchor api})";

                      mkBulkMd =
                        concatMapStringsSep "\n" (endpoint: ''
                          ${mkApiLink endpoint.name}
                          ${endpoint.extraHtml or ""}
                          ${
                            if endpoint ? tryButton && !endpoint.tryButton
                            then ""
                            else if endpoint ? buttonHtml
                            then endpoint.buttonHtml endpoint.name
                            else mkPostButton endpoint.name
                          }

                          ---

                        '')
                        endpoints;

                      markdown = builtins.toFile "index.md" ''
                        APIs exposed through this interface:

                        ---

                        ${mkBulkMd}
                      '';
                    in
                      pkgs.runCommand "nginx-root-dir" {buildInputs = [pkgs.pandoc];} ''
                        mkdir $out
                        pandoc \
                          --standalone \
                          --embed-resources \
                          --metadata title="IPFS APIs Available" \
                          -f markdown \
                          -t html5 \
                          -c ${githubCss} \
                          -o $out/index.html \
                          ${markdown}
                      '';
                  }
                  proxyPassApis
                  {
                    "/api/v0/add".extraConfig = ''
                      # Fixes interrupted uploads with progress=true
                      # Ref: https://github.com/ipfs/kubo/issues/6402#issuecomment-1085266811
                      client_max_body_size ${toString cfg.maxUploadSizeMB}M;
                      proxy_buffering off;
                      proxy_http_version 1.1;
                      proxy_request_buffering off;
                    '';
                  }
                ];
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
