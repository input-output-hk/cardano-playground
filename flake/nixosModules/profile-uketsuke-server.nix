flake: {
  flake.nixosModules.profile-uketsuke-server = {
    config,
    lib,
    pkgs,
    name,
    ...
  }: let
    inherit (flake.config.flake.cardano-parts.cluster.infra.aws) domain region profile;
    inherit (groupCfg) groupName groupFlake;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;

    # The signer refuses a plaintext origin that is not loopback, so the
    # origin signed into every manifest is this nginx vhost.
    serverName = "uketsuke-leios.${domain}";
    listenPort = 4100;

    # Loopback only and never proxied: nginx forwards all of listenPort to the
    # public, so /metrics has a port of its own that only alloy scrapes.
    metricsPort = 4101;

    # Both are signed into every manifest and handed to pools in campaign.json,
    # so changing either one invalidates every campaign.json already sent out.
    # The magic ties the network name to this genesis, as uketsuke's reference
    # asks.
    inherit (config.cardano-parts.perNode.lib) cardanoLib;
    inherit (groupCfg.meta) environmentName;
    network = "${environmentName}-${toString cardanoLib.environments.${environmentName}.peerSnapshot.NetworkMagic}";
    campaign = "glue";

    # Uploads admitted at once, across all pools. Each holds up to
    # max_file_bytes of staging on / for up to upload_timeout.
    maxInflight = 4;

    # Below maxInflight, so one address cannot hold every upload slot, and
    # above one, so a pool can fetch a receipt while an upload is in flight.
    connectionsPerAddress = 2;
  in {
    assertions = [
      {
        # The roster is the one metsuke-server's timer writes; without that
        # timer nothing refreshes it and every upload gets a 503.
        assertion = config.services.metsuke-server.roster.enable;
        message = "${name} runs uketsuke, which reads the Leios key roster written by services.metsuke-server.roster, but that timer is off.";
      }
    ];

    # Root-owned: systemd reads it as root and uketsuke runs under DynamicUser.
    sops.secrets = mkSopsSecret {
      secretName = "uketsuke-aws-env";
      keyName = "${name}-uketsuke-aws.env";
      inherit groupOutPath groupName name;
      fileOwner = "root";
      fileGroup = "root";
      restartUnits = [config.systemd.services.uketsuke.name];
    };

    # The roster generator's output is 0640 to its own group.
    systemd.services.uketsuke.serviceConfig.SupplementaryGroups = ["metsuke-roster"];

    security.acme = {
      acceptTerms = true;
      defaults.email = "devops@iohk.io";
    };

    services = {
      uketsuke = {
        enable = true;
        package = flake.inputs.uketsuke.packages.x86_64-linux.uketsuke;

        environmentFile = config.sops.secrets.uketsuke-aws-env.path;
        rosterFile = config.services.metsuke-server.roster.file;
        nginx.enable = true;

        settings = {
          service = "https://${serverName}";
          inherit network campaign;
          campaign_lifetime = "55m";
          clock_skew = "5m";

          # The metsuke archive bucket under a prefix the uketsuke IAM user in
          # the bootstrap workspace is limited to.
          s3_bucket = "${profile}-metsuke";
          s3_region = region;
          s3_endpoint = "https://s3.${region}.amazonaws.com";
          s3_prefix = "uketsuke/v1/${campaign}/";
          s3_timeout = "30s";

          port = listenPort;
          metrics_port = metricsPort;
          max_file_bytes = 100 * 1024 * 1024;
          upload_timeout = "2m";
          progress_interval = "15s";
          max_inflight = maxInflight;

          # Lifetime of the campaign's ledger, counted in signed ZIP bytes.
          # Reservations are never reclaimed, so once this is spent every upload
          # gets 507 until a new campaign prefix starts a new ledger.
          max_total_bytes = 10 * 1024 * 1024 * 1024;

          # Sent base64 in one header, about 5.5 KiB at this size, under nginx's
          # default 8k large_client_header_buffers line limit.
          max_manifest_bytes = 4096;

          # Measured on the file's mtime. The roster timer runs hourly from its
          # last start, plus its accuracy window and run time, so one hour would
          # refuse every upload for a moment each tick. Three hours rides out two
          # failed runs, e.g. while the node is behind the tip.
          roster_max_age = "3h";
        };
      };

      # The route filter on the vhost below is a vts directive.
      nginx-vhost-exporter.enable = true;

      alloy.extraAlloyConfig = ''
        prometheus.scrape "integrations_uketsuke" {
          targets = [{
            __address__ = "127.0.0.1:${toString metricsPort}",
            ${lib.concatStringsSep ",\n    " (lib.mapAttrsToList (n: v: "${n} = \"${v}\"") config.services.alloy.labels)},
          }]
          forward_to = [prometheus.remote_write.integrations.receiver]
          job_name = "integrations/uketsuke"
          metrics_path = "/metrics"
        }
      '';

      nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;

        appendHttpConfig = ''
          limit_conn_zone $binary_remote_addr zone=uketsukeConn:10m;
          limit_req_zone $binary_remote_addr zone=uketsukeUpload:10m rate=30r/m;
          limit_req_zone $binary_remote_addr zone=uketsukeHealth:10m rate=60r/m;

          # A fixed set of route names for the vts filter below; keying on $uri
          # would make every submission id its own series.
          map $uri $uketsukeRoute {
            ~^/v1/uploads/ upload;
            ~^/v1/receipts/ receipt;
            ~^/campaigns/ site;
            / site;
            /healthz health;
            default other;
          }
        '';

        virtualHosts.${serverName} = {
          enableACME = true;
          forceSSL = true;

          # In the server block, not the http block: metsuke's profile already
          # sets both status codes there, and a second http-level line is a
          # duplicate.
          extraConfig = ''
            limit_conn_status 429;
            limit_req_status 429;
            limit_conn uketsukeConn ${toString connectionsPerAddress};
            vhost_traffic_status_filter_by_set_key $uketsukeRoute route::$server_name;
          '';

          locations = {
            "/".extraConfig = ''
              limit_req zone=uketsukeUpload burst=16 nodelay;
            '';

            # Probes never eat upload budget.
            "= /healthz".extraConfig = "limit_req zone=uketsukeHealth burst=10 nodelay;";
          };
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      config.services.nginx.defaultHTTPListenPort
      config.services.nginx.defaultSSLListenPort
    ];
  };
}
