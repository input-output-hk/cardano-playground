{moduleWithSystem, ...}: {
  flake.nixosModules.cardano-tx-centrifuge = moduleWithSystem ({inputs'}: {
    config,
    pkgs,
    lib,
    ...
  }: let
    serviceName = "cardano-tx-centrifuge";
    settingsFormat = pkgs.formats.json {};
    cfg = config.services.cardano-tx-centrifuge;
  in {
    options.services.${serviceName} = {
      enable = lib.mkEnableOption "tx-centrifuge";

      package = lib.mkPackageOption inputs'.cardano-node-leios-bench.packages "tx-centrifuge" {};

      useLocalCardanoNode = {
        nodeConfig =
          lib.mkEnableOption "using the local cardano-node's config"
          // {
            default = config.services.cardano-node.enable;
          };

        recycling =
          lib.mkEnableOption "using the local cardano-node for recycling"
          // {
            default = config.services.cardano-node.enable;
          };
      };

      fundsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to JSON file that contains the mapping of UTxOs to their lovelace amount.
          Can be imported from output of `scripts/playground/fund-centrifuge.nu get-funds --json`,
        '';
      };

      fundsSigningKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path at runtime to the signing key for the funds.
        '';
      };

      settings = lib.mkOption {
        inherit (settingsFormat) type;
        default = {};
        description = "Overrides deep-merged on top of the module defaults for centrifuge.json.";
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        services.${serviceName}.settings = {
          initial_inputs = {
            type = "genesis_utxo_keys";
            params.signing_keys_file = "/run/${serviceName}/funds.json";
          };

          builder = {
            type = "value";
            params = {
              inputs_per_tx = lib.mkDefault 1;
              outputs_per_tx = lib.mkDefault 1;
              fee = lib.mkDefault 1000000;
            };
          };

          rate_limit = {
            type = lib.mkDefault "token_bucket";
            scope = lib.mkDefault "shared";
            params.tps = lib.mkDefault 100;
          };

          max_batch_size = lib.mkDefault 10;
        };

        systemd.services.${serviceName} = {
          wantedBy = ["multi-user.target"];

          preStart = let
            filter = ''
              to_entries | map({
                tx_in: .key,
                value: .value,
                signing_key: "\(env.CREDENTIALS_DIRECTORY)/funds.skey",
              })
            '';
          in ''
            ${lib.getExe pkgs.jaq} ${lib.escapeShellArg filter} "$CREDENTIALS_DIRECTORY"/funds.json > "$RUNTIME_DIRECTORY"/funds.json
          '';

          enableStrictShellChecks = true;

          serviceConfig = {
            ExecStart = toString [
              (lib.getExe cfg.package)
              (settingsFormat.generate "centrifuge.json" cfg.settings)
            ];

            DynamicUser = true;

            LoadCredential = [
              "funds.json:${cfg.fundsFile}"
              "funds.skey:${cfg.fundsSigningKeyFile}"
            ];

            RuntimeDirectory = serviceName;
          };
        };
      }

      (lib.mkIf cfg.useLocalCardanoNode.nodeConfig {
        services.${serviceName}.settings.nodeConfig = with config.services.cardano-node;
          if nodeConfigFile != null
          then nodeConfigFile
          else pkgs.writers.writeJSON "node-config.json" nodeConfig;
      })

      (lib.mkIf cfg.useLocalCardanoNode.recycling {
        services = {
          ${serviceName}.settings = {
            builder.recycle = {
              type = "on_confirm";
              params = "local-follower";
            };

            observers.local-follower = {
              type = "nodetoclient";
              params = {
                confirmation_depth = 2;
                socket_path = config.services.cardano-node.socketPath 0;
              };
            };
          };

          cardano-node.shareNodeSocket = true;
        };

        systemd.services.${serviceName} = rec {
          requisite = [
            "cardano-node.service"
            "cardano-node-socket-share.service"
          ];
          after = requisite;

          serviceConfig.SupplementaryGroups = lib.singleton config.services.cardano-node.socketGroup;
        };
      })
    ]);
  });
}
