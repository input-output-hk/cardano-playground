_: {
  flake.nixosModules.leios-files-nginx = {
    config,
    lib,
    name,
    pkgs,
    ...
  }: let
    inherit (groupCfg.meta) domain;
    groupCfg = config.cardano-parts.cluster.group;
    cfg = config.services.leios-files-nginx;
    indexDir = "/var/lib/leios-files-nginx";
  in {
    # Profile to serve the cardano-node 'leios.*' files (e.g. leios.db, leios.sqlite,
    # leios snapshot artifacts) over HTTP. The on-disk db-leios/ subdir is
    # NOT exposed; only files matching leios.* directly in the data
    # directory are served. When enableIndex is on (the default), an HTML
    # listing of the served files is rendered at '/'.
    options.services.leios-files-nginx = {
      serverName = lib.mkOption {
        type = lib.types.str;
        default = "${name}.${domain}";
        description = ''
          nginx server_name (FQDN) under which the files are served, and
          the ACME TLS cert name when enableAcme is true. Defaults to
          `''${name}.''${domain}` of the machine importing this module,
          where `name` is the colmena node name and `domain` comes from
          `cardano-parts.cluster.group.meta.domain`.
        '';
      };

      serverAliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra FQDN aliases to be added to the ACME TLS cert and nginx virtualHost.";
      };

      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/cardano-node";
        description = "Directory containing leios.* files to serve.";
      };

      dataGroup = lib.mkOption {
        type = lib.types.str;
        default = "cardano-node";
        description = ''
          POSIX group that owns the leios.* files. nginx is added to this
          group so it can read them. Files must be group-readable (mode
          0640 or wider) — if cardano-node creates them 0600 you'll need
          to relax that, e.g. by setting UMask in its unit or running a
          one-shot chmod hook.
        '';
      };

      acmeEmail = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The default contact email to be used for ACME certificate acquisition.";
      };

      acmeProd = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to use the ACME TLS production server for certificate requests (vs the staging server).";
      };

      enableAcme = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to obtain an ACME TLS cert for nginx and force HTTPS.";
      };

      enableIndex = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to expose an HTML index of available leios.* files at
          the virtualHost root. A small oneshot service regenerates the
          index page by listing leios.* files in dataDir on a timer; the
          result is served by nginx at `/`. Set false to revert `/` to a
          strict 404.
        '';
      };

      indexRefreshInterval = lib.mkOption {
        type = lib.types.str;
        default = "1min";
        description = ''
          systemd OnUnitActiveSec interval for regenerating the index
          page. Snapshot artifacts change infrequently, so a minute is
          fine for ops UX. Tighten for testing.
        '';
      };

      openFirewallNginx = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to open the firewall TCP ports used by nginx: 80, 443.";
      };

      extraLocations = lib.mkOption {
        type = with lib.types; attrsOf anything;
        default = {};
        description = ''
          Extra nginx 'locations' to merge into the virtualHost. The
          leios-file regex location and the `/` index/deny location are
          added on top.
        '';
      };
    };

    config = {
      # nginx needs read access to the leios.* files.
      users.users.nginx.extraGroups = [cfg.dataGroup];

      services.nginx = {
        enable = true;

        # Sensible production defaults; cheap to enable.
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedTlsSettings = true;
        recommendedProxySettings = false;

        virtualHosts.${cfg.serverName} = {
          inherit (cfg) serverAliases;
          forceSSL = cfg.enableAcme;
          enableACME = cfg.enableAcme;

          locations = lib.mkMerge [
            cfg.extraLocations
            {
              # Match only files named 'leios.<something>' (no slashes →
              # no descent into db-leios/ or any other subdir).
              "~ ^/(leios\\.[^/]+)$" = {
                root = cfg.dataDir;
                extraConfig = ''
                  # Long-lived static artifacts; allow client caching but
                  # require revalidation so updated dumps are picked up.
                  add_header Cache-Control "public, max-age=300, must-revalidate";

                  # Don't reveal nginx version on 404 / error pages.
                  server_tokens off;
                '';
              };

              # Strict 404 for anything not matched above. Crucially this
              # catches /db-leios/... which would otherwise be visible via
              # 'root'. When enableIndex is on, the exact-match '= /'
              # location below takes precedence over this for the bare
              # root, but everything else still 404s.
              "/" = {
                return = "404";
              };
            }
            (lib.mkIf cfg.enableIndex {
              # Exact match: only the bare root '/' serves the index.
              # Any other path (e.g. '/foo') still falls to the '/' prefix
              # location above and 404s, so the index dir isn't browsable.
              "= /" = {
                root = indexDir;
                extraConfig = ''
                  try_files /index.html =404;
                '';
              };
            })
          ];
        };
      };

      # Index dir owned by nginx so the regen service (running as nginx)
      # can write to it and nginx itself can read it.
      systemd = lib.mkIf cfg.enableIndex {
        tmpfiles.rules = [
          "d ${indexDir} 0755 nginx nginx -"
        ];

        services.leios-files-nginx-index = {
          description = "Regenerate leios.* file index page";
          wantedBy = ["multi-user.target"];
          after = ["nginx.service"];
          path = [pkgs.coreutils];
          serviceConfig = {
            Type = "oneshot";
            User = "nginx";
            Group = "nginx";
          };
          script = ''
            target=${indexDir}/index.html
            tmp=$(mktemp ${indexDir}/index.html.XXXXXX)
            trap 'rm -f "$tmp"' EXIT

            {
              printf '%s\n' '<!doctype html>'
              printf '%s\n' '<html><head><meta charset="utf-8">'
              printf '<title>leios files on %s</title>\n' '${cfg.serverName}'
              printf '%s\n' '<style>'
              printf '%s\n' 'body{font-family:sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem}'
              printf '%s\n' 'table{border-collapse:collapse;width:100%}'
              printf '%s\n' 'th,td{padding:.4rem .8rem;border-bottom:1px solid #ddd;text-align:left}'
              printf '%s\n' 'th{background:#f4f4f4}'
              printf '%s\n' 'td.size{text-align:right;font-family:monospace}'
              printf '%s\n' 'a{color:#0a58ca;text-decoration:none}a:hover{text-decoration:underline}'
              printf '%s\n' '.meta{color:#666;font-size:.85em;margin-top:1.5rem}'
              printf '%s\n' '</style></head><body>'
              printf '<h1>leios files on %s</h1>\n' '${cfg.serverName}'
              printf '%s\n' '<table>'
              printf '%s\n' '<thead><tr><th>file</th><th>size (bytes)</th><th>modified (UTC)</th></tr></thead>'
              printf '%s\n' '<tbody>'

              count=0
              for f in ${cfg.dataDir}/leios.*; do
                [ -f "$f" ] || continue
                fname=$(basename "$f")
                fsize=$(stat -c %s "$f")
                fmtime=$(date -u -d "@$(stat -c %Y "$f")" '+%Y-%m-%d %H:%M:%S')
                printf '<tr><td><a href="/%s">%s</a></td><td class="size">%s</td><td>%s</td></tr>\n' \
                  "$fname" "$fname" "$fsize" "$fmtime"
                count=$((count + 1))
              done

              printf '%s\n' '</tbody></table>'
              if [ "$count" -eq 0 ]; then
                printf '%s\n' '<p><em>No leios.* files present in '"${cfg.dataDir}"' yet.</em></p>'
              fi
              printf '<p class="meta">Index regenerated %s.</p>\n' "$(date -u +'%Y-%m-%d %H:%M:%SZ')"
              printf '%s\n' '</body></html>'
            } > "$tmp"

            chmod 0644 "$tmp"
            mv -f "$tmp" "$target"
          '';
        };

        timers.leios-files-nginx-index = {
          description = "Periodic regeneration of leios.* file index page";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = cfg.indexRefreshInterval;
            Unit = "leios-files-nginx-index.service";
          };
        };
      };

      security.acme = lib.mkIf cfg.enableAcme {
        acceptTerms = true;
        defaults = {
          email = cfg.acmeEmail;
          server =
            if cfg.acmeProd
            then "https://acme-v02.api.letsencrypt.org/directory"
            else "https://acme-staging-v02.api.letsencrypt.org/directory";
        };
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewallNginx [80 443];
    };
  };
}
