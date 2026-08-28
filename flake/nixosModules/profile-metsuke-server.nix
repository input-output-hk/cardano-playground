flake: {
  flake.nixosModules.profile-metsuke-server = {
    config,
    lib,
    pkgs,
    name,
    ...
  }: let
    inherit (flake.config.flake.cardano-parts.cluster.infra.aws) domain region;
    inherit (groupCfg) groupName groupFlake;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;

    # An agent refuses a plaintext upload_url that is not loopback, so the
    # operator-facing name is this nginx vhost and never the server's port.
    serverName = "metsuke-leios.${domain}";
    listenPort = 8080;

    inherit ((builtins.fromTOML (builtins.readFile ./metsuke-allowlist.toml)).ingest) allowlist;

    maxBodyBytes = 1048576;
  in {
    assertions = [
      {
        assertion = allowlist != {};
        message = "flake/nixosModules/metsuke-allowlist.toml holds no pools, and an empty allowlist refuses every submission. Generate it with metsuke-allowlist, as its header says.";
      }
    ];

    sops.secrets = lib.mkMerge [
      # Root-owned rather than service-owned: systemd reads both of these as
      # root, and metsuke-server runs under DynamicUser, so no service user
      # exists to own them.
      (mkSopsSecret {
        secretName = "metsuke-aws-env";
        keyName = "${name}-metsuke-aws.env";
        inherit groupOutPath groupName name;
        fileOwner = "root";
        fileGroup = "root";
        restartUnits = [config.systemd.services.metsuke-server.name];
      })
      (mkSopsSecret {
        secretName = "metsuke-developer-password";
        keyName = "${name}-metsuke-developer-password";
        inherit groupOutPath groupName name;
        fileOwner = "root";
        fileGroup = "root";
        restartUnits = [config.systemd.services.metsuke-server.name];
      })
    ];

    services = {
      cardano-node.enable = lib.mkForce false;
      metsuke-server = {
        enable = true;

        developerPasswordFile = config.sops.secrets.metsuke-developer-password.path;
        environmentFile = config.sops.secrets.metsuke-aws-env.path;

        # Field for field from contrib/server.example.toml in the metsuke repo,
        # which is where each value's reason is written down. Only the three
        # marked below are ours to decide.
        settings = {
          listen = "127.0.0.1:${toString listenPort}";

          http = {
            idle_timeout_ms = 30000;
            read_timeout_ms = 60000;
            write_timeout_ms = 60000;
            max_concurrent_requests = 64;
          };

          # Ours: the bucket the bootstrap workspace creates.
          archive.s3 = {
            bucket = "${flake.config.flake.cardano-parts.cluster.infra.aws.profile}-metsuke";
            inherit region;
            endpoint = "https://s3.${region}.amazonaws.com";
            request_timeout_ms = 30000;
            signature_validity_secs = 300;
            put_retries = 1;
            put_retry_backoff_ms = 500;
            list_max_pages = 1000;
          };

          ingest = {
            # Ours: generated, never hand-written.
            inherit allowlist;

            max_body_bytes = maxBodyBytes;
            max_header_bytes = 4096;
            rate_limit_uploads = 100;
            rate_limit_uploads_total = 2000;
            rate_limit_window_secs = 3600;
          };

          developer = {
            user = "metsuke-dev";
            list_max_rows = 1000;
          };
        };
      };
    };

    security.acme = {
      acceptTerms = true;
      defaults.email = "devops@iohk.io";
    };

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      virtualHosts.${serverName} = {
        enableACME = true;
        forceSSL = true;

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString listenPort}";

          # nginx's own default is 1m, the same as max_body_bytes, so a batch
          # at exactly the limit would be refused here instead of reaching the
          # server that decides it.
          extraConfig = "client_max_body_size ${toString (2 * maxBodyBytes)};";
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      config.services.nginx.defaultHTTPListenPort
      config.services.nginx.defaultSSLListenPort
    ];
  };
}
