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

    inherit ((fromTOML (builtins.readFile ./metsuke-allowlist.toml)).ingest) allowlist;

    inherit (config.cardano-parts.perNode.lib) cardanoLib;
    environment = cardanoLib.environments.${groupCfg.meta.environmentName};

    # At least the agent's upload_batch_max_bytes, which is what it seals before
    # compression and what this counts after it. Set under that, a submission
    # compressing worse than the gap earns a 413, which the agent reads as
    # terminal and reseals identically, so the same body is refused until its
    # spool cap drops those rows.
    maxBodyBytes = 4194304;
  in {
    assertions = [
      {
        assertion = allowlist != {};
        message = "flake/nixosModules/metsuke-allowlist.toml holds no pools, and an empty allowlist refuses every submission. Generate it with metsuke-allowlist, as its header says.";
      }
      {
        # When off the roster is refused by the node socket and the Requisite names
        # a unit nothing defines, neither of which says why.
        assertion = config.services.cardano-node.shareNodeSocket;
        message = "${name} generates the Leios key roster, which reaches the node socket by group, so services.cardano-node.shareNodeSocket has to be on.";
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
      # The roster generator reaches the socket by group, which only the unit
      # this turns on makes writable.
      cardano-node.shareNodeSocket = true;
      metsuke-server = {
        enable = true;

        developerPasswordFile = config.sops.secrets.metsuke-developer-password.path;
        environmentFile = config.sops.secrets.metsuke-aws-env.path;

        # The timer that writes the Leios key roster (ADR 0011). It queries
        # this host's own node, which is why the node runs here rather than
        # being forced off.
        roster = {
          enable = true;
          package = flake.inputs.metsuke.packages.x86_64-linux.metsuke-roster;

          cardanoCli = config.cardano-parts.perNode.pkgs.cardano-cli;
          era = "dijkstra";
          network.testnetMagic = environment.peerSnapshot.NetworkMagic;

          socketPath = config.services.cardano-node.socketPath 0;
          inherit (config.services.cardano-node) socketGroup;

          # Well inside an epoch, because this is the ceiling on how long a
          # pool's key rotation takes to be accepted, and a run that fails
          # leaves the previous roster in place.
          interval = "1h";
        };

        # Field for field from contrib/server.example.toml in the metsuke repo,
        # which is where each value's reason is written down. Only the ones
        # marked below are ours to decide.
        settings = {
          listen = "127.0.0.1:${toString listenPort}";

          http = {
            idle_timeout_ms = 30000;
            read_timeout_ms = 60000;
            write_timeout_ms = 60000;
            # Ours: headroom for a deploy, which is when every agent uploads at
            # once. An agent sends its first submission at startup and only then
            # takes a place within upload_jitter_max_secs, so a fleet brought up
            # together arrives together that once and is spread from the next
            # interval on. A permit is taken before accept and a body is read
            # whole, so this times max_body_bytes is the ceiling on bodies held
            # in memory, and this host also runs a node.
            max_concurrent_requests = 128;
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

            # The timer's own path, so the two cannot name different files.
            # Set this once this host's node has caught up: the server refuses
            # to start without a readable roster, and the generator writes none
            # off a node short of the tip, so setting it earlier stops cold-key
            # submissions too while nothing yet signs with a Leios key.
            leios_roster = config.services.metsuke-server.roster.file;

            max_body_bytes = maxBodyBytes;
            max_header_bytes = 4096;
            max_timestamp_skew_secs = 300;
            # Sized for the expected fleet, each agent draining its spool
            # rather than sending one submission a tick. Steady state is a
            # handful of uploads an hour each; the room above that is for the
            # burst when many drain a backlog at once.
            rate_limit_uploads = 300;
            rate_limit_uploads_total = 20000;
            rate_limit_window_secs = 3600;
          };

          developer = {
            user = "metsuke-dev";
            list_max_rows = 1000;
          };
        };
      };
    };

    # shareNodeSocket makes the socket group-writable from its own unit, so the
    # group alone is not enough: a run before that lands finds the socket there
    # and unwritable. Requisite rather than wants, so a tick that is too early
    # fails at once and the timer takes the next one.
    systemd.services.metsuke-roster = rec {
      requisite = [
        "cardano-node.service"
        "cardano-node-socket-share.service"
      ];
      after = requisite;
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

      # metsuke-server holds one global semaphore of max_concurrent_requests
      # and takes a permit before accept, so connections past it wait in the
      # backlog. The semaphore does not know who holds a slot, and the read and
      # idle timeouts are deliberately generous for pools on bad links, so one
      # address can hold every slot for a minute at a time. Keying that on the
      # address is nginx's to do; the server states so in its own http.rs.
      appendHttpConfig = ''
        limit_conn_zone $binary_remote_addr zone=metsukeConn:10m;
        limit_req_zone $binary_remote_addr zone=metsukeSubmit:10m rate=60r/m;
        limit_conn_status 429;
        limit_req_status 429;
      '';

      virtualHosts.${serverName} = {
        enableACME = true;
        forceSSL = true;

        # Well under the server's own permit count, and well over what a pool
        # needs: an agent uploads a tick's submissions one after the other on
        # one connection, and several agents behind one egress address upload on
        # a jittered hourly cadence. This is what keeps one address off those
        # permits; the request limit above is not.
        extraConfig = "limit_conn metsukeConn 8;";

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString listenPort}";

          # nginx's own default is 1m, the same as max_body_bytes, so a batch
          # at exactly the limit would be refused here instead of reaching the
          # server that decides it.
          extraConfig = "client_max_body_size ${toString (2 * maxBodyBytes)};";
        };

        # The rate limit is the submission path's alone. A developer sync pulls
        # one object per request as fast as the listing feeds it, so rate
        # limiting the download route would throttle the tool that reads the
        # archive.
        #
        # An agent uploads hourly but no longer once: a tick drains each stream
        # up to upload_max_submissions, so it arrives as a burst of up to 17 and
        # is then silent for an hour. The burst has to clear a whole tick, and
        # several agents behind one egress address at that. What keeps one
        # address off the server's slots is limit_conn below, not this.
        locations."/v1/submit" = {
          proxyPass = "http://127.0.0.1:${toString listenPort}";

          extraConfig = ''
            client_max_body_size ${toString (2 * maxBodyBytes)};
            limit_req zone=metsukeSubmit burst=64 nodelay;
          '';
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      config.services.nginx.defaultHTTPListenPort
      config.services.nginx.defaultSSLListenPort
    ];
  };
}
