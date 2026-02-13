{
  flake.nixosModules.metrics-scraper = {
    config,
    lib,
    pkgs,
    name,
    ...
  }: let
    cfg = config.services.metrics-scraper;
  in {
    options.services.metrics-scraper = {
      nodeName = lib.mkOption {
        type = lib.types.str;
        example = "production-server-01";
        default = name;
        description = "Node name to include in the output filename";
      };

      metricsUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://localhost:12798/metrics";
        description = "URL to scrape metrics from";
      };

      outputDirectory = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/metrics-scraper";
        description = "Directory where scrape files will be stored";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "*:0/1";
        example = "*:0/1";
        description = "Systemd calendar expression for scrape interval (default: every minute)";
      };
    };

    config = {
      systemd = {
        services.metrics-scraper = {
          description = "Scrape metrics from ${cfg.metricsUrl}";
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            WorkingDirectory = "/var/lib/metrics-scraper";
            StateDirectory = "metrics-scraper";
            ExecStart = pkgs.writeShellScript "scrape-metrics" ''
              set -uo pipefail

              umask 077
              TIMESTAMP=$(${pkgs.coreutils}/bin/date +%s)
              OUTPUT_FILE="scrape-${cfg.nodeName}-$TIMESTAMP.txt"

              ${pkgs.curl}/bin/curl -s "${cfg.metricsUrl}" 2>&1 | install -m 600 /dev/stdin "$OUTPUT_FILE" || true
            '';
          };
        };

        timers.metrics-scraper = {
          description = "Timer for metrics scraper";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = cfg.interval;
            AccuracySec = "1us"; # high accuracy timing
            Persistent = false; # don't catch up on missed runs
            Unit = "metrics-scraper.service";
          };
        };
      };
    };
  };
}
