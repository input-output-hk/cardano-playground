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

    # Exactly the four keys the signer accepts. The server takes any lifetime
    # up to maxLifetimeSecs; this is the one pools sign with.
    campaignConfig = {
      service = "https://${serverName}";
      inherit network campaign;
      lifetime_secs = 900;
    };
    maxLifetimeSecs = 3600;

    maxFileBytes = 100 * 1024 * 1024;
    uploadTimeoutMs = 120000;
    s3TimeoutMs = 30000;

    # Uploads admitted at once, across all pools. Each holds up to
    # max_file_bytes of staging on / for up to upload_timeout_ms.
    maxInflight = 4;

    # Below maxInflight, so one address cannot hold every upload slot, and
    # above one, so a pool can fetch a receipt while an upload is in flight.
    connectionsPerAddress = 2;

    # nginx starts this timer once the unbuffered body is sent. From there
    # the server reserves quota (one s3_timeout_ms deadline across every ledger
    # read and conditional write retry) and PUTs the bundle (one more), and the
    # third covers writing the bundle before that PUT.
    proxyReadTimeoutSecs = 3 * s3TimeoutMs / 1000;

    # The signer pools run is the release this server is built from: flake.nix
    # pins uketsuke to the tag of its package version.
    signerVersion = config.services.uketsuke.package.version;
    signerTag = "v${signerVersion}";
    repoUrl = "https://github.com/input-output-hk/uketsuke";
    releaseUrl = "${repoUrl}/releases/download/${signerTag}";
    signerBinary = "uketsuke-sign-${signerVersion}-x86_64-linux";
    campaignPath = "/campaigns/${campaign}.json";

    # Served from the vhost so pools fetch campaign.json from the service it
    # names, generated from the same values the server is configured with.
    site = let
      campaignJson = pkgs.writeText "${campaign}.json" (builtins.toJSON campaignConfig);
      indexHtml = pkgs.writeText "index.html" ''
        <!doctype html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Uketsuke · ${network}</title>
        <style>
          :root { color-scheme: light dark; --fg: #1c1c1c; --bg: #fafaf8; --muted: #666; --line: #ddd; --code: #f0efea; --accent: #0b6e4f; }
          @media (prefers-color-scheme: dark) { :root { --fg: #e8e8e4; --bg: #161616; --muted: #9a9a9a; --line: #333; --code: #222; --accent: #5ccf9f; } }
          body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.55 system-ui, sans-serif; }
          main { max-width: 50rem; margin: 0 auto; padding: 2.5rem 1rem 4rem; }
          h1 { margin: 0; font-size: 1.9rem; }
          h1 small { color: var(--muted); font-weight: 400; font-size: 1rem; margin-left: .5rem; }
          h2 { margin-top: 2.2rem; font-size: 1.15rem; border-bottom: 1px solid var(--line); padding-bottom: .3rem; }
          a { color: var(--accent); }
          code, pre { font: .9em/1.5 ui-monospace, monospace; background: var(--code); border-radius: 4px; }
          code { padding: .1em .3em; overflow-wrap: anywhere; }
          pre { padding: .8rem 1rem; overflow-x: auto; font-size: .82em; }
          table { border-collapse: collapse; width: 100%; }
          th, td { text-align: left; padding: .4rem .6rem .4rem 0; border-bottom: 1px solid var(--line); vertical-align: top; }
          th { color: var(--muted); font-weight: 500; width: 11rem; }
          .download { margin-top: 1rem; }
          ol { padding-left: 1.4rem; }
          li { margin-bottom: 1rem; }
          li pre { margin: .5rem 0; }
          .muted { color: var(--muted); }
        </style>
        <main>
          <h1>Uketsuke <small>受付, reception desk</small></h1>
          <p>The report inbox for the Leios testnet <code>${network}</code>. A pool signs a ZIP report locally with its Leios BLS key and uploads it here. The signing key never leaves the pool's machine, and each accepted report gets a receipt.</p>

          <h2>Current campaign</h2>
          <table>
            <tr><th>Campaign</th><td><code>${campaign}</code></td></tr>
            <tr><th>Network</th><td><code>${network}</code></td></tr>
            <tr><th>Service</th><td><code>${campaignConfig.service}</code></td></tr>
            <tr><th>Request lifetime</th><td>${toString campaignConfig.lifetime_secs} s from signing</td></tr>
            <tr><th>Largest report</th><td>${toString (maxFileBytes / 1024 / 1024)} MiB</td></tr>
            <tr><th>Accepted keys</th><td>Leios BLS keys registered on chain, from a roster refreshed hourly</td></tr>
            <tr><th>Signer</th><td><a href="${repoUrl}/releases/tag/${signerTag}">uketsuke ${signerTag}</a></td></tr>
          </table>
          <p class="download"><a href="${campaignPath}">Download ${campaign}.json</a> <span class="muted">· <a href="/healthz">service status</a></span></p>
          <p class="muted">SHA-256 <code>@sha256@</code></p>

          <h2>Upload a report</h2>
          <p>Needs curl 7.76.0 or newer. <code>POOL_HEX</code> is your pool's 56-character lowercase hex ID.</p>
          <ol>
            <li>Fetch the campaign.
              <pre>curl -fsSLO ${campaignConfig.service}${campaignPath}</pre></li>
            <li>Sign the report, with Nix:
              <pre>nix run github:input-output-hk/uketsuke/${signerTag}#uketsuke-sign -- \
          --key /secure/path/bls.skey --file report.zip --pool POOL_HEX \
          --campaign ${campaign}.json --out request</pre>
              or without Nix, with the release's static binary:
              <pre>release=${releaseUrl}
        curl -fsSLO $release/${signerBinary}
        curl -fsSLO $release/SHA256SUMS
        sha256sum -c --ignore-missing SHA256SUMS
        chmod +x ${signerBinary}
        ./${signerBinary} \
          --key /secure/path/bls.skey --file report.zip --pool POOL_HEX \
          --campaign ${campaign}.json --out request</pre>
              <p class="muted">On aarch64 use <code>uketsuke-sign-${signerVersion}-aarch64-linux</code>; it is built and checksummed but not smoke-tested.</p></li>
            <li>Upload it.
              <pre>curl -q -K request/upload.curl</pre></li>
          </ol>
          <p>Save the receipt the upload prints, and keep the report and the <code>request</code> directory until you have it. Retries, receipt recovery and error responses are in the <a href="${repoUrl}/blob/${signerTag}/docs/reference.md#upload-details">upload details</a>.</p>
        </main>
        </html>
      '';
    in
      pkgs.runCommand "uketsuke-site" {} ''
        mkdir -p $out/campaigns
        cp ${campaignJson} $out${campaignPath}
        substitute ${indexHtml} $out/index.html \
          --subst-var-by sha256 "$(sha256sum ${campaignJson} | cut -d' ' -f1)"
      '';

    # Store files all carry mtime 1, so nginx's Last-Modified and ETag would
    # call a changed page unchanged; make browsers refetch instead.
    staticConfig = ''
      root ${site};
      etag off;
      if_modified_since off;
      add_header Cache-Control "no-cache";
    '';
  in {
    assertions = [
      {
        # The roster is the one metsuke-server's timer writes; without that
        # timer nothing refreshes it and every upload gets a 503.
        assertion = config.services.metsuke-server.roster.enable;
        message = "${name} runs uketsuke, which reads the Leios key roster written by services.metsuke-server.roster, but that timer is off.";
      }
      {
        assertion = campaignConfig.lifetime_secs <= maxLifetimeSecs;
        message = "${name}: campaign.json hands pools lifetime_secs ${toString campaignConfig.lifetime_secs}, over the server's max_lifetime_secs ${toString maxLifetimeSecs}, so every upload would be refused.";
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

        settings = {
          inherit (campaignConfig) service network campaign;

          # The metsuke archive bucket under a prefix the uketsuke IAM user in
          # the bootstrap workspace is limited to.
          s3_bucket = "${profile}-metsuke";
          s3_region = region;
          s3_endpoint = "https://s3.${region}.amazonaws.com";
          s3_prefix = "uketsuke/v1/${campaign}/";
          s3_timeout_ms = s3TimeoutMs;

          port = listenPort;
          metrics_port = metricsPort;
          max_file_bytes = maxFileBytes;
          upload_timeout_ms = uploadTimeoutMs;
          max_inflight = maxInflight;

          # Lifetime of the campaign's ledger, counted in signed ZIP bytes.
          # Reservations are never reclaimed, so once this is spent every upload
          # gets 507 until a new campaign prefix starts a new ledger.
          max_total_bytes = 10 * 1024 * 1024 * 1024;

          max_lifetime_secs = maxLifetimeSecs;

          # Sent base64 in one header, about 5.5 KiB at this size, under nginx's
          # default 8k large_client_header_buffers line limit.
          max_manifest_bytes = 4096;

          # Measured on the file's mtime. The roster timer runs hourly from its
          # last start, plus its accuracy window and run time, so one hour would
          # refuse every upload for a moment each tick. Three hours rides out two
          # failed runs, e.g. while the node is behind the tip.
          roster_max_age_secs = 3 * 3600;
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
            "/" = {
              proxyPass = "http://127.0.0.1:${toString listenPort}";

              # Unbuffered so the server's admission check (roster key, quota,
              # in-flight slot) runs before the body is read, rather than after
              # nginx has spooled up to max_file_bytes to disk. client_body_timeout
              # is per read; the server holds the whole-body deadline.
              extraConfig = ''
                client_max_body_size ${toString maxFileBytes};
                proxy_request_buffering off;
                proxy_send_timeout ${toString (uploadTimeoutMs / 1000)}s;
                proxy_read_timeout ${toString proxyReadTimeoutSecs}s;
                limit_req zone=uketsukeUpload burst=16 nodelay;
              '';
            };

            # Public for the blackbox probe. It costs uketsuke one stat of the
            # roster, and is limited on its own so probes never eat upload budget.
            "= /healthz" = {
              proxyPass = "http://127.0.0.1:${toString listenPort}";
              extraConfig = "limit_req zone=uketsukeHealth burst=10 nodelay;";
            };

            # The campaign page; try_files serves it here rather than handing
            # /index.html back to the proxied location /.
            "= /".extraConfig = ''
              ${staticConfig}
              try_files /index.html =404;
            '';
            "/campaigns/".extraConfig = staticConfig;
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
