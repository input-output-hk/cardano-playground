{
  flake.nixosModules.buildkite-auto-gc = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.services.auto-gc;
    inherit (lib) types mkIf mkOption;
  in {
    options = {
      services.auto-gc = {
        nixAutoGcEnable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to perform an auto GC.  Default true.";
        };

        nixAutoMaxFreedGB = mkOption {
          type = types.int;
          default = 110;
          description = "An maximum absolute amount to free up to on the auto GC";
        };

        nixAutoMinFreeGB = mkOption {
          type = types.int;
          default = 30;
          description = "The minimum amount to trigger an auto GC at";
        };

        nixHourlyGcEnable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to perform an hourly GC.  Default true.";
        };

        nixHourlyMaxFreedGB = mkOption {
          type = types.int;
          default = 110;
          description = "The maximum absolute level to free up to on the /nix/store mount for the hourly timed GC";
        };

        nixHourlyMinFreeGB = mkOption {
          type = types.int;
          default = 20;
          description = "The minimum amount to trigger the /nix/store mount hourly timed GC at";
        };

        nixWeeklyGcFull = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to perform a full GC weekly.  Default false.";
        };

        nixWeeklyGcOnCalendar = mkOption {
          type = types.str;
          default = "Sat *-*-* 20:00:00";
          description = "The default weekly day and time to perform a full GC, if enabled.  Uses systemd onCalendar format.";
        };
      };
    };

    config = {
      nix = mkIf cfg.nixAutoGcEnable {
        # This GC is run automatically by nix-build
        extraOptions = ''
          # Try to ensure between ${toString cfg.nixAutoMinFreeGB}G and ${toString cfg.nixAutoMaxFreedGB}G of free space by
          # automatically triggering a garbage collection if free
          # disk space drops below a certain level during a build.
          min-free = ${toString (cfg.nixAutoMinFreeGB * 1024 * 1024 * 1024)}
          max-free = ${toString (cfg.nixAutoMaxFreedGB * 1024 * 1024 * 1024)}
        '';
      };

      systemd.services = {
        gc-hourly = mkIf cfg.nixHourlyGcEnable {
          script = ''
            free=$(${pkgs.coreutils}/bin/df --block-size=M --output=avail /nix/store | tail -n1 | sed s/M//)
            echo "Automatic GC: ''${free}M available"
            # Set the max absolute level to free to nixHourlyMaxFreedGB on the /nix/store mount
            if [ $free -lt ${toString (cfg.nixHourlyMinFreeGB * 1024)} ]; then
              ${config.nix.package}/bin/nix-collect-garbage --max-freed ${toString (cfg.nixHourlyMaxFreedGB * 1024 * 1024 * 1024)}
            fi
          '';
        };

        gc-weekly = mkIf cfg.nixWeeklyGcFull {
          script = "${config.nix.package}/bin/nix-collect-garbage";
        };
      };

      systemd.timers = {
        gc-hourly = mkIf cfg.nixHourlyGcEnable {
          timerConfig = {
            Unit = "gc-hourly.service";
            OnCalendar = "*-*-* *:15:00";
          };
          wantedBy = ["timers.target"];
        };

        gc-weekly = mkIf cfg.nixWeeklyGcFull {
          timerConfig = {
            Unit = "gc-weekly.service";
            OnCalendar = cfg.nixWeeklyGcOnCalendar;
          };
          wantedBy = ["timers.target"];
        };
      };
    };
  };
}
