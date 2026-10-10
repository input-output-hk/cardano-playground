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
    inherit (lib) mkDefault;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;
  in {
    sops.secrets = mkSopsSecret {
      secretName = "tx-centrifuge-fund-key";
      keyName = "${name}-fund.skey";
      inherit groupOutPath groupName name;
      fileOwner = "root";
      fileGroup = "root";
      restartUnits = [config.systemd.services.cardano-tx-centrifuge.name];
    };

    services.cardano-tx-centrifuge = {
      enable = true;

      # Single skey: tx-centrifuge derives every recycle address from this
      # key. Operator funds at least workload 0's address before starting;
      # initial UTxOs are discovered on-chain at every startup.
      signingKeyFile = "/run/secrets/tx-centrifuge-fund-key";

      settings = {
        rate_limit.params.tps = mkDefault 100;

        workloads.synthetic-chain.targets = mkDefault (
          lib.mapAttrs
          (name: {config, ...}: {
            addr = "${name}.${domain}";
            inherit (config.services.cardano-node) port;
          })
          (
            lib.filterAttrs
            (name: _: lib.hasPrefix "leios" name && lib.hasInfix "-rel-" name)
            nodes
          )
        );
      };
    };
  };
}
