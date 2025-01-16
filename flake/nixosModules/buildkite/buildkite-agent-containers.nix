flake @ {
  self,
  moduleWithSystem,
  ...
}: {
  flake.nixosModules.buildkite-agent-containers = moduleWithSystem ({system}: {
    config,
    lib,
    pkgs,
    name,
    ...
  }: let
    inherit (opsLib) mkSopsSecret;

    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;

    groupOutPath = self.group.outPath;

    cfg = config.services.buildkite-containers;

    mkSopsSecretParams = secretName: keyName: mode: path: {
      inherit groupOutPath name secretName keyName;
      groupName = "N/A";
      pathPrefix = "${self}/secrets/buildkite/";
      fileOwner = "buildkite-agent-iohk";
      fileGroup = "buildkite-agent-iohk";
      extraCfg = {
        inherit mode;
        path = "${path}/${secretName}";
      };
    };
  in
    with lib; {
      imports = [
        # Common host level config (also applied at guest level)
        {
          nix = {
            settings.system-features = ["kvm" "big-parallel" "nixos-test" "benchmark"];
            nixPath = ["nixpkgs=/run/current-system/nixpkgs"];
          };
        }

        # GC only from the host to avoid duplicating GC in containers
        self.nixosModules.buildkite-auto-gc

        # Docker module required in both the host and guest containers
        self.nixosModules.buildkite-docker-builder
      ];

      options = {
        services.buildkite-containers = {
          hostIdSuffix = mkOption {
            type = types.str;
            default = "1";
            description = ''
              A host identifier suffix which is typically a CI server number and is used
              as part of the container name.  Container names are limited to 7 characters,
              so the default naming convention is ci''${hostIdSuffix}-''${containerNum}.
              An example container name, using a hostIdSuffix of 2 for example, may then
              be ci2-4, indicating a 4th CI container on a 2nd host CI server.
            '';
            example = "1";
          };

          queue = mkOption {
            type = types.str;
            default = "default";
            description = ''
              The queue the buildite agent is configured to accept jobs for.
            '';
            example = "1";
          };

          containerList = mkOption {
            type = types.listOf types.attrs;
            default = [
              {
                containerName = "ci${cfg.hostIdSuffix}-1";
                guestIp = "10.254.1.11";
                prio = "9";
                tags.queue = cfg.queue;
              }
              {
                containerName = "ci${cfg.hostIdSuffix}-2";
                guestIp = "10.254.1.12";
                prio = "8";
                tags.queue = cfg.queue;
              }
              {
                containerName = "ci${cfg.hostIdSuffix}-3";
                guestIp = "10.254.1.13";
                prio = "7";
                tags.queue = cfg.queue;
              }
              {
                containerName = "ci${cfg.hostIdSuffix}-4";
                guestIp = "10.254.1.14";
                prio = "6";
                tags.queue = cfg.queue;
              }
            ];
            description = ''
              This parameter allows container customization on a per server basis.
              The default is for 4 buildkite containers.
              Note that container names cannot be more than 7 characters.
            '';
            example = ''
              [ { containerName = "ci1-1"; guestIp = "10.254.1.11"; tags = { system = "x86_64-linux"; queue = "custom"; }; } ];
            '';
          };

          weeklyCachePurge = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to delete the shared /cache dir weekly";
          };

          weeklyCachePurgeOnCalendar = mkOption {
            type = types.str;
            default = "Sat *-*-* 20:00:00";
            description = "The default weekly day and time to perform a weekly /cache dir and swap purge, if enabled.  Uses systemd onCalendar format.";
          };
        };
      };

      config = let
        createBuildkiteContainer = {
          containerName, # The desired container name
          hostIp ? "10.254.1.1", # The IPv4 host virtual eth nic IP
          guestIp ? "10.254.1.11", # The IPv4 container guest virtual eth nic IP
          tags ? {system = "x86_64-linux";}, # Agent metadata customization
          prio ? null, # Agent priority
        }: {
          name = containerName;
          value = {
            autoStart = true;

            bindMounts = {
              "/cache" = {
                hostPath = "/cache";
                isReadOnly = false;
              };

              "/run/keys" = {
                hostPath = "/run/keys";
              };

              "/run/secrets" = {
                hostPath = "/run/secrets";
              };

              "/var/lib/buildkite-agent/hooks" = {
                hostPath = "/var/lib/buildkite-agent/hooks";
              };
            };

            privateNetwork = true;
            hostAddress = hostIp;
            localAddress = guestIp;
            specialArgs.name = name;

            config = {
              imports = [
                # Set up
                self.inputs.cardano-parts.nixosModules.profile-common
                self.nixosModules.common

                # Prevent nix sandbox related failures
                self.nixosModules.buildkite-nix-nsswitch

                # Docker module required in both the host and guest containers
                self.nixosModules.buildkite-docker-builder
              ];

              # The cardano-parts basic profile breaks containers, so declare a
              # subset of that module here rather than importing directly
              time.timeZone = "UTC";
              i18n.supportedLocales = ["en_US.UTF-8/UTF-8" "en_US/ISO-8859-1"];

              documentation = {
                nixos.enable = false;
                man.man-db.enable = false;
                info.enable = false;
                doc.enable = false;
              };

              environment = {
                # Don't try to inherit resolved from the host which won't work
                etc = {
                  "resolv.conf".text = ''
                    nameserver 8.8.8.8
                  '';

                  # Globally enable stack's nix integration so that stack builds have
                  # the necessary dependencies available.
                  "stack/config.yaml".text = ''
                    nix:
                      enable: true
                  '';
                };

                systemPackages = with pkgs; [
                  bat
                  bind
                  dnsutils
                  fd
                  fx
                  file
                  git
                  glances
                  helix
                  htop
                  ijq
                  icdiff
                  jiq
                  jq
                  lsof
                  nano
                  # For nix >= 2.24 build compatibility
                  self.inputs.nixpkgs-unstable.legacyPackages.${system}.neovim
                  ncdu
                  ripgrep
                  smem
                  tcpdump
                  tree
                  wget
                ];
              };

              services = {
                chrony = {
                  enable = true;
                  extraConfig = "rtcsync";
                  enableRTCTrimming = false;
                };

                cron.enable = true;

                openssh = {
                  enable = true;
                  settings = {
                    PasswordAuthentication = false;
                    RequiredRSASize = 2048;
                    PubkeyAcceptedAlgorithms = "-*nist*";
                  };
                };
              };

              system.extraSystemBuilderCmds = ''
                ln -sv ${pkgs.path} $out/nixpkgs
              '';

              nix = {
                nixPath = ["nixpkgs=/run/current-system/nixpkgs"];
                package = self.inputs.cardano-parts.inputs.nix.packages.${system}.nix;
                registry.nixpkgs.flake = self.inputs.nixpkgs;

                # Setting this true will typically induce iowait at ~50% level for
                # several minutes each day on already IOPS constrained ec2 ebs gp3 and
                # similarly capable machines, which in turn may impact performance for
                # capability sensitive software.  While cardano-node itself doesn't
                # appear to be impacted by this in terms of observable missedSlots on
                # forgers or delayed headers reported by blockperf, this will be
                # disabled as a precaution.
                optimise.automatic = false;

                gc.automatic = true;

                settings = {
                  auto-optimise-store = true;
                  builders-use-substitutes = true;
                  experimental-features = ["nix-command" "fetch-closure" "flakes" "cgroups"];
                  keep-derivations = true;
                  keep-outputs = true;
                  max-jobs = "auto";
                  show-trace = true;
                  substituters = ["https://cache.iog.io"];
                  system-features = ["recursive-nix" "kvm" "big-parallel" "nixos-test" "benchmark"];
                  tarball-ttl = 60 * 60 * 72;
                  trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
                };
              };

              # Set the state version to the current nixpkgs being used to avoid trace warns
              system.stateVersion = lib.mkDefault config.system.nixos.release;

              # Ensure we can use same nixpkgs with overlays the host uses
              nixpkgs.pkgs = pkgs;

              systemd.services.buildkite-agent-iohk.serviceConfig = {
                ExecStart = mkForce "${pkgs.buildkite-agent}/bin/buildkite-agent start --config /var/lib/buildkite-agent-iohk/buildkite-agent.cfg";
                LimitNOFILE = 1024 * 512;
              };

              services.buildkite-agents.iohk = {
                name = "ci" + "-" + name + "-" + containerName;
                privateSshKeyPath = "/run/keys/buildkite-ssh-iohk-devops-private";
                tokenPath = "/run/keys/buildkite-token";
                inherit tags;
                runtimePackages = with pkgs; [
                  bash
                  gnutar
                  gzip
                  bzip2
                  xz
                  git
                  git-lfs
                  self.inputs.cardano-parts.inputs.nix.packages.${system}.nix
                ];

                hooks = {
                  environment = ''
                    # Provide a minimal build environment
                    export NIX_BUILD_SHELL="/run/current-system/sw/bin/bash"
                    export PATH="/run/current-system/sw/bin:$PATH"

                    # Provide NIX_PATH, unless it's already set by the pipeline
                    if [ -z "''${NIX_PATH:-}" ]; then
                        # See system.extraSystemBuilderCmds
                        export NIX_PATH="nixpkgs=/run/current-system/nixpkgs"
                    fi

                    # Load S3 credentials for artifact upload
                    # shellcheck source=/dev/null
                    source /var/lib/buildkite-agent/hooks/aws-creds

                    # Load extra credentials for user services
                    # shellcheck source=/dev/null
                    source /var/lib/buildkite-agent/hooks/buildkite-extra-creds
                  '';

                  pre-command = ''
                    # Clean out the state that gets messed up and makes builds fail.
                    rm -rf ~/.cabal
                  '';

                  pre-exit = ''
                    echo "Cleaning up the /tmp directory..."

                    # Some jobs leave /tmp directories which are not writeable, preventing direct deletion.
                    echo "Change moding buildkite agent owned /tmp/* files and directories recursively in preparation for cleanup..."
                    find /tmp/* -maxdepth 0 -type f,d -user buildkite-agent-iohk -print0 | xargs -0 -r chmod -R +w || true

                    # Use print0 to handle special filenames and rm -rf to also unlink live and broken symlinks and other special file types.
                    echo "Removing buildkite agent owned /tmp/* directories..."
                    find /tmp/* -maxdepth 0 -type d -user buildkite-agent-iohk -print0 | xargs -0 -r rm -rvf || true

                    echo "Removing buildkite agent owned /tmp top level files which are not buildkite agent job dependent..."
                    find /tmp/* -maxdepth 0 -type f \( ! -iname "buildkite-agent*" -and ! -iname "job-env-*" \) -user buildkite-agent-iohk -print0 | xargs -0 -r rm -vf || true

                    # Avoid prematurely deleting buildkite agent related job files and causing job failures.
                    echo "Removing buildkite agent owned /tmp top level files older than 1 day..."
                    find /tmp/* -maxdepth 0 -type f -mmin +1440 -user buildkite-agent-iohk -print0 | xargs -0 -r rm -vf || true

                    # Clean up the scratch directory
                    echo "Cleaning up the /scratch directory..."
                    rm -rf /scratch/* &> /dev/null || true

                    echo "Cleanup of /tmp and /scratch complete."
                  '';
                };

                extraConfig = ''
                  git-clean-flags="-ffdqx"
                  ${
                    if prio != null
                    then "priority=${prio}"
                    else ""
                  }
                '';
              };

              users.users.buildkite-agent-iohk = {
                isSystemUser = true;
                group = "buildkite-agent-iohk";
                # To ensure buildkite-agent-iohk user sharing of keys in guests
                uid = 10000;
                extraGroups = [
                  "keys"
                  "docker"
                ];
              };

              users.groups.buildkite-agent-iohk = {
                gid = 10000;
              };

              systemd.services.buildkite-agent-custom = {
                wantedBy = ["buildkite-agent-iohk.service"];
                script = ''
                  mkdir -p /build /scratch
                  chown -R buildkite-agent-iohk:buildkite-agent-iohk /build /scratch
                '';
                serviceConfig = {
                  Type = "oneshot";
                };
              };
            };
          };
        };
      in {
        # Secrets target file naming is to be backwards compatible with the legacy deployment
        # and other scripts which may rely on the legacy naming.
        sops.secrets =
          mkSopsSecret (mkSopsSecretParams "aws-creds" "buildkite-hook" "0550" "/var/lib/buildkite-agent/hooks")
          // mkSopsSecret (mkSopsSecretParams "buildkite-extra-creds" "buildkite-hook-extra-creds.sh" "0550" "/var/lib/buildkite-agent/hooks")
          // mkSopsSecret (mkSopsSecretParams "buildkite-ssh-private" "buildkite-ssh" "0400" "/run/keys")
          // mkSopsSecret (mkSopsSecretParams "buildkite-ssh-public" "buildkite-ssh.pub" "0400" "/run/keys")
          // mkSopsSecret (mkSopsSecretParams "buildkite-ssh-iohk-devops-private" "buildkite-iohk-devops-ssh" "0400" "/run/keys")
          // mkSopsSecret (mkSopsSecretParams "buildkite-hackage-ssh-private" "buildkite-hackage-ssh" "0400" "/run/keys")
          // mkSopsSecret (mkSopsSecretParams "buildkite-stackage-ssh-private" "buildkite-stackage-ssh" "0400" "/run/keys")
          // mkSopsSecret (mkSopsSecretParams "buildkite-haskell-dot-nix-ssh-private" "buildkite-haskell-dot-nix-ssh" "0400" "/run/keys")
          // mkSopsSecret (mkSopsSecretParams "buildkite-cardano-wallet-ssh-private" "buildkite-cardano-wallet-ssh" "0400" "/run/keys")
          // mkSopsSecret (mkSopsSecretParams "buildkite-token" "buildkite_token" "0400" "/run/keys")
          // mkSopsSecret (mkSopsSecretParams "dockerhub-auth" "dockerhub-auth-config.json" "0400" "/run/keys");

        # The buildkite host machine will need to be deployed twice before
        # the /cache directory will be properly owned since the first deployment
        # will have the activation run before the buildkite-agent-iohk user
        # exists.
        system.activationScripts.cacheDir = {
          text = ''
            mkdir -p /cache
            chown -R buildkite-agent-iohk:buildkite-agent-iohk /cache || true
          '';
          deps = [];
        };

        users.users.buildkite-agent-iohk = {
          home = "/var/lib/buildkite-agent";
          isSystemUser = true;
          createHome = true;
          group = "buildkite-agent-iohk";

          # To ensure buildkite-agent-iohk user sharing of keys in guests
          uid = 10000;
        };

        users.groups.buildkite-agent-iohk = {
          gid = 10000;
        };

        environment.etc."mdadm.conf".text = ''
          MAILADDR root
        '';

        environment.systemPackages = [pkgs.nixos-container];

        networking.nat = {
          enable = true;
          internalInterfaces = ["ve-+"];
          externalInterface = "ens5";
        };

        services.fstrim.enable = true;
        services.fstrim.interval = "daily";

        systemd.services.weekly-cache-purge = mkIf cfg.weeklyCachePurge {
          script = ''
            rm -rf /cache/* || true

            # There is no swap enabled on the std aws instances
            # ${pkgs.utillinux}/bin/swapoff -a
            # ${pkgs.utillinux}/bin/swapon -a
          '';
        };

        systemd.timers.weekly-cache-purge = mkIf cfg.weeklyCachePurge {
          timerConfig = {
            Unit = "weekly-cache-purge.service";
            OnCalendar = cfg.weeklyCachePurgeOnCalendar;
          };
          wantedBy = ["timers.target"];
        };

        containers = builtins.listToAttrs (map createBuildkiteContainer cfg.containerList);
      };
    });
}
