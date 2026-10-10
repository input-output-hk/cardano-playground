flake: {
  flake.nixosModules.profile-leios-tx-firehose = {
    config,
    pkgs,
    name,
    ...
  }: let
    inherit (groupCfg) groupName groupFlake;
    inherit (config.cardano-parts.perNode.lib) cardanoLib;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;
    environment = cardanoLib.environments.${groupCfg.meta.environmentName};
  in {
    sops.secrets = mkSopsSecret {
      secretName = "tx-firehose-fund-key";
      keyName = "${name}-firehose-fund.skey";
      inherit groupOutPath groupName name;
      fileOwner = "root";
      fileGroup = "root";
      restartUnits = [config.systemd.services.cardano-tx-firehose.name];
    };

    services.cardano-tx-firehose = {
      enable = true;

      # One key per instance. The address is the payment key hash, with no
      # per workload derivation, so two instances sharing a key spend each
      # other's UTxOs and reject as AllInputsAreSpent.
      signingKeyFile = "/run/secrets/tx-firehose-fund-key";

      testnetMagic = environment.peerSnapshot.NetworkMagic;
    };
  };
}
