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

    infra.generic = {
      organization = "iog";
      tribe = "coretech";
      function = "cardano-parts";
      repo = "https://github.com/input-output-hk/cardano-playground";

      # These options must remain true for the playground cluster as ip info is required
      abortOnMissingIpModule = true;
      warnOnMissingIpModule = true;
    };

    infra.grafana.stackName = "playground";

    groups = let
      dns = infra.aws.domain;
      mkGroup = name: environmentName: bookRelayMultivalueDns: groupRelayMultivalueDns: isNg: {
        ${name} =
          {
            inherit bookRelayMultivalueDns groupRelayMultivalueDns;
            groupPrefix = "${name}-";
            meta = {inherit environmentName;};
          }
          // optionalAttrs isNg {
            # For the latest genesis only compatible with >= node 8.5.0
            lib.cardanoLib = flake.config.flake.cardano-parts.pkgs.special.cardanoLibNg;

            # Until upstream parts ng has capkgs version, use local flake pins
            pkgs = {
              cardano-cli = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-cli-ng);
              cardano-db-sync = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-db-sync-ng);
              cardano-db-tool = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-db-tool-ng);
              cardano-db-sync-pkgs = flake.config.flake.cardano-parts.pkgs.special.cardano-db-sync-pkgs-ng;
              cardano-faucet = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-faucet-ng);
              cardano-node = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-node-ng);
              cardano-smash = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-smash-ng);
              cardano-submit-api = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-submit-api-ng);
              cardano-node-pkgs = flake.config.flake.cardano-parts.pkgs.special.cardano-node-pkgs-ng;
              mithril-client-cli = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.mithril-client-cli-ng);
              mithril-signer = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.mithril-signer-ng);
            };
          };
      };
    in
      (mkGroup "preprod1" "preprod" "preprod-node.${dns}" "preprod1-node.${dns}" false)
      // (mkGroup "preprod2" "preprod" "preprod-node.${dns}" "preprod2-node.${dns}" false)
      // (mkGroup "preprod3" "preprod" "preprod-node.${dns}" "preprod3-node.${dns}" false)
      // (mkGroup "preview1" "preview" "preview-node.${dns}" "preview1-node.${dns}" false)
      // (mkGroup "preview2" "preview" "preview-node.${dns}" "preview2-node.${dns}" false)
      // (mkGroup "preview3" "preview" "preview-node.${dns}" "preview3-node.${dns}" false)
      // (mkGroup "private1" "private" "private-node.${dns}" "private1-node.${dns}" true)
      // (mkGroup "private2" "private" "private-node.${dns}" "private2-node.${dns}" true)
      // (mkGroup "private3" "private" "private-node.${dns}" "private3-node.${dns}" true)
      # Flip sanchonet and shelley-qa back to isNg true for sanchonet respin and shelley-qa 8.10 deployed
      // (mkGroup "sanchonet1" "sanchonet" "sanchonet-node.${dns}" "sanchonet1-node.${dns}" true)
      // (mkGroup "sanchonet2" "sanchonet" "sanchonet-node.${dns}" "sanchonet2-node.${dns}" true)
      // (mkGroup "sanchonet3" "sanchonet" "sanchonet-node.${dns}" "sanchonet3-node.${dns}" true)
      // (mkGroup "shelley-qa1" "shelley_qa" "shelley-qa-node.${dns}" "shelley-qa1-node.${dns}" false)
      // (mkGroup "shelley-qa2" "shelley_qa" "shelley-qa-node.${dns}" "shelley-qa2-node.${dns}" false)
      // (mkGroup "shelley-qa3" "shelley_qa" "shelley-qa-node.${dns}" "shelley-qa3-node.${dns}" false)
      // (mkGroup "mainnet1" "mainnet" null null false)
      // (mkGroup "misc1" "preprod" null null false);
  };
}
