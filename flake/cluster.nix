flake @ {withSystem, ...}:
with flake.lib; {
  # Define some cluster-wide configuration.
  # This has to evaluate fast and is imported in various places.
  flake.cardano-parts.cluster = rec {
    infra.aws = {
      orgId = "362174735783";
      region = "eu-central-1";
      profile = "cardano-playground";

      # Set a region to false to set its count to 0 in terraform.
      # After applying once you can remove the line.
      regions = {
        eu-central-1 = true;
        eu-west-1 = true;
        us-east-2 = true;
      };

      domain = "play.dev.cardano.org";

      # Preset defaults matched to default terraform rain infra; change if desired:
      # kms = "arn:aws:kms:${region}:${orgId}:alias/kmsKey";
      # bucketName = "${profile}-terraform";
    };

    infra.grafana.stackName = "cardanoplayground";

    groups = let
      mkGroup = name: environmentName: groupRelayMultivalueDns: isNg: {
        ${name} =
          {
            inherit groupRelayMultivalueDns;
            groupPrefix = "${name}-";
            meta = {inherit environmentName;};
          }
          // optionalAttrs isNg {
            # For the latest genesis only compatible with >= node 8.5.0
            lib.cardanoLib = flake.config.flake.cardano-parts.pkgs.special.cardanoLibNg;

            # Until upstream parts ng has capkgs version, use local flake pins
            pkgs.cardano-cli = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-cli-ng);
            pkgs.cardano-db-sync = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-db-sync-ng);
            pkgs.cardano-db-tool = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-db-tool-ng);
            pkgs.cardano-db-sync-pkgs = flake.config.flake.cardano-parts.pkgs.special.cardano-db-sync-pkgs-ng;
            pkgs.cardano-faucet = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-faucet-ng);
            pkgs.cardano-node = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-node-ng);
            pkgs.cardano-smash = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-smash-ng);
            pkgs.cardano-submit-api = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-submit-api-ng);
            pkgs.cardano-node-pkgs = flake.config.flake.cardano-parts.pkgs.special.cardano-node-pkgs-ng;
          };
      };
    in
      (mkGroup "preprod1" "preprod" "preprod.${infra.aws.domain}" false)
      // (mkGroup "preprod2" "preprod" null false)
      // (mkGroup "preprod3" "preprod" null false)
      // (mkGroup "preview1" "preview" "preview.${infra.aws.domain}" false)
      // (mkGroup "preview2" "preview" null false)
      // (mkGroup "preview3" "preview" null false)
      // (mkGroup "sanchonet1" "sanchonet" "sanchonet.${infra.aws.domain}" true)
      // (mkGroup "sanchonet2" "sanchonet" null true)
      // (mkGroup "sanchonet3" "sanchonet" null true)
      // (mkGroup "mainnet1" "mainnet" null false);
  };
}
