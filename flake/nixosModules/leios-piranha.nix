{
  self,
  inputs,
  config,
  ...
}: let
  inherit (config.flake.cardano-parts.cluster.infra.aws) domain;
in {
  flake.nixosModules.leios-piranha = {
    name,
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.cardano-leios-piranha;
  in {
    imports = [
      inputs.leios-adversarial-tools.nixosModules.net-node
    ];

    # This option namespace already exists (from the module imported above).
    # We are extending it with additional options.
    options.services.cardano-leios-piranha = {
      flakeRef = lib.mkOption {
        type = lib.types.str;
        default = (import (self + /flake.nix)).inputs.leios-adversarial-tools.url;
        description = ''
          The flake ref to build on update requests.
        '';
      };

      mutablePackagePath = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/cardano-leios-piranha/package";
        description = ''
          Where to link the build result of {option}`services.cardano-leios-piranha.flakeRef`.
        '';
      };

      netClusterIp4 = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = ''
          The IPv4 of the net-cluster command & control server to whitelist.
        '';
      };

      netClusterIp6 = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = ''
          The IPv6 of the net-cluster command & control server to whitelist.
        '';
      };
    };

    config = lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.services.cardano-node.enable or false;
          message = ''
            The normal cardano-node service needs to be enabled on this machine.
            While the piranha node does not depend on it, the point
            of this module extension is to switch which node is active on demand.
          '';
        }
      ];

      environment.shellAliases.piranha = "curl --insecure --header 'Host: ${name}.${domain}' https://[::1]/piranha";

      services = {
        cardano-leios-piranha = {
          conflictWithNode = true;

          keys.coldVkey = config.sops.secrets.cardano-node-cold-verification.path;

          configs = [
            # Written on startup, see systemd service additions below.
            "/run/cardano-leios-piranha/pool-id.toml"
          ];

          settings = let
            inherit (config.cardano-parts.perNode.lib) cardanoLib;
            inherit (config.cardano-parts.cluster) group;
            environment = cardanoLib.environments.${group.meta.environmentName};
          in {
            network_magic = environment.peerSnapshot.NetworkMagic;
            genesis_path = environment.nodeConfig.ShelleyGenesisFile;
            leios_enabled = true;

            sync_method = "tip";
            scheduler = "priority-wfq";

            chain_data = {
              source = "kleioscan";
              network = "musashi";
            };

            external_nodes =
              lib.imap (i: {
                addr,
                port,
              }: {
                id = "${environment.name}-edge${toString i}";
                address = "${addr}:${toString port}";
                connect.kind = "all";
              })
              environment.edgeNodes;
          };
        };

        nginx = {
          enable = true;

          recommendedGzipSettings = true;
          recommendedOptimisation = true;
          recommendedTlsSettings = true;
          recommendedProxySettings = true;

          virtualHosts."${name}.${domain}" = {
            forceSSL = true;
            enableACME = true;

            locations."= /piranha" = {
              fastcgiParams.SCRIPT_FILENAME = let
                writeNuStdin = name: argsOrScript:
                  pkgs.writeShellScript "${name}-wrapper" (
                    "exec ${lib.getExe pkgs.nushell} --no-config-file --stdin "
                    + pkgs.writers.writeNu name argsOrScript
                  );
              in
                writeNuStdin "piranha-handler" ''
                  use std/util 'path add'

                  const unit_piranha = ${builtins.toJSON config.systemd.services.cardano-leios-piranha.name}
                  const unit_node = ${builtins.toJSON config.systemd.services.cardano-node.name}
                  const package_path = ${builtins.toJSON cfg.mutablePackagePath}

                  def main []: string -> nothing {
                    let req_body = $in

                    (
                      path add
                      ${lib.getBin config.nix.package}/bin
                      ${lib.getBin pkgs.gitMinimal}/bin
                    )

                    mut status = 500
                    mut content_type = 'text/plain'

                    let res_body = match $env.REQUEST_METHOD {
                      GET => {
                        $status = 200
                        $content_type = 'application/json'
                        {
                          active: (systemctl is-active $unit_piranha | collect)
                          path: (
                            if ($package_path | path type) == symlink {
                              nix path-info --json --json-format 2 $package_path | from json
                            } else null
                          )
                        } | to json
                      }
                      POST => {
                        $status = 204
                        match $req_body {
                          start => {
                            systemctl start $unit_piranha
                          }
                          stop => {
                            systemctl start $unit_node
                          }
                          restart => {
                            systemctl restart $unit_piranha
                          }
                          update => (
                            nix build
                            --print-build-logs
                            --print-out-paths
                            --out-link $package_path
                            ${builtins.toJSON cfg.flakeRef}
                          )
                          _ => {
                            $status = 400
                            'Request body must contain only one of "start", "stop", "restart", and "update"'
                          }
                        }
                      }
                      _ => {$status = 405}
                    }

                    print --no-newline $"Status: ($status)\r\n"
                    print --no-newline $"Content-Type: ($content_type)\r\n\r\n"
                    print --no-newline $res_body
                  }
                '';
              extraConfig =
                ''
                  allow 127.0.0.1;
                  allow ::1;
                ''
                + lib.optionalString (cfg.netClusterIp4 != null) ''
                  allow ${cfg.netClusterIp4};
                ''
                + lib.optionalString (cfg.netClusterIp6 != null) ''
                  allow ${cfg.netClusterIp6};
                ''
                + ''
                  deny  all;

                  fastcgi_pass unix:${config.services.fcgiwrap.instances.piranha.socket.address};
                '';
            };
          };
        };

        fcgiwrap.instances.piranha = {
          socket = {
            user = "nginx";
            group = "nginx";
          };
          process = {
            user = "root";
            group = "root";
          };
        };
      };

      systemd.services.cardano-leios-piranha = rec {
        # mkBefore to override `cfg.package`
        path = lib.mkBefore [
          cfg.mutablePackagePath
          config.cardano-parts.perNode.pkgs.cardano-cli
        ];

        # not in `preStart` because `$CREDENTIALS_DIRECTORY` does not work with `DynamicUser=`
        script = lib.mkBefore ''
          # Read the pool ID into a separate config file.
          pool_id_cred="$CREDENTIALS_DIRECTORY/cold.vkey"
          pool_id_config=/run/${serviceConfig.RuntimeDirectory}/pool-id.toml
          touch "$pool_id_config" # make sure it exists so startup does not fail
          if [[ -f "$pool_id_cred" ]]; then
            printf '[keys]\npool_id = "' > "$pool_id_config"
            cardano-cli latest \
              stake-pool id \
              --cold-verification-key-file "$pool_id_cred" \
              --output-format bech32 \
              >> "$pool_id_config"
            printf '"\n' >> $pool_id_config
          fi
        '';

        serviceConfig.RuntimeDirectory = "cardano-leios-piranha";
      };
    };
  };
}
