flake: {
  flake.nixosModules.profile-leios-tx-centrifuge = {
    config,
    pkgs,
    lib,
    name,
    nodes,
    ...
  }: let
    inherit (flake.config.flake.cardano-parts.cluster.infra.aws) domain;
    inherit (groupCfg) groupName groupFlake;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;
  in {
    sops.secrets =
      mkSopsSecret {
        secretName = "tx-centrifuge-fund-key";
        keyName = "${name}-fund.skey";
        inherit groupOutPath groupName name;
        fileOwner = "root";
        fileGroup = "root";
        restartUnits = [config.systemd.services.cardano-tx-centrifuge.name];
      }
      // mkSopsSecret {
        secretName = "tx-centrifuge-fund";
        keyName = "${name}-fund.json";
        inherit groupOutPath groupName name;
        fileOwner = "root";
        fileGroup = "root";
        restartUnits = [config.systemd.services.cardano-tx-centrifuge.name];
      };

    services.cardano-tx-centrifuge = {
      enable = true;

      fundsFile = "/run/secrets/tx-centrifuge-fund";
      fundsSigningKeyFile = "/run/secrets/tx-centrifuge-fund-key";

      settings = {
        initial_inputs.params.network_magic = 164;

        rate_limit.params.tps = 100;

        workloads.synthetic-chain.targets =
          lib.mapAttrs
          (name: {config, ...}: {
            addr = "${name}.${domain}";
            inherit (config.services.cardano-node) port;
          })
          (
            lib.filterAttrs
            (name: _: lib.hasPrefix "leios" name && lib.hasInfix "-rel-" name)
            nodes
          );
      };
    };
  };
}
