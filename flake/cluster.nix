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

        # Temporary machine usage in these regions for buildkite one-off tests
        af-south-1 = true;
        ap-southeast-2 = true;
        sa-east-1 = true;
      };

      domain = "play.dev.cardano.org";

      # Preset defaults matched to default terraform rain infra; change if desired:
      # kms = "arn:aws:kms:${region}:${orgId}:alias/kmsKey";
      # bucketName = "${profile}-terraform";
    };

    infra.generic = {
      organization = "ioe";
      tribe = "coretech";
      function = "cardano-parts";
      repo = "https://github.com/input-output-hk/cardano-playground";

      owner = "ioe";
      environment = "testnets";
      project = "cardano-playground";

      # This is the tf var secrets name located in secrets/tf/cluster.tfvars
      costCenter = "tag_costCenter";

      # These options must remain true for the playground cluster as ip info is required
      abortOnMissingIpModule = true;
      warnOnMissingIpModule = true;
    };

    infra.grafana.stackName = "playground";

    groups = let
      dns = infra.aws.domain;
      mkGroup = name: environmentName: bookRelayMultivalueDns: groupRelayMultivalueDns: isNg: fullHostsList: {
        ${name} =
          {
            inherit bookRelayMultivalueDns groupRelayMultivalueDns;
            groupPrefix = "${name}-";
            meta = {inherit environmentName;};

            # Setting fullHostsList true will place all cluster machines in the
            # /etc/hosts file instead of just each group member being placed.
            #
            # One use case for this might be if there is node localRoots
            # meshing required between groups.
            meta.hostsList =
              if fullHostsList
              then "all"
              else "group";
          }
          // optionalAttrs isNg {
            lib.cardanoLib = flake.config.flake.cardano-parts.pkgs.special.cardanoLibNg;

            pkgs = {
              cardano-cli = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-cli-ng);
              cardano-db-sync-pkgs = flake.config.flake.cardano-parts.pkgs.special.cardano-db-sync-pkgs-ng;
              cardano-db-sync = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-db-sync-ng);
              cardano-db-tool = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-db-tool-ng);
              cardano-faucet = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-faucet-ng);
              cardano-node-pkgs = flake.config.flake.cardano-parts.pkgs.special.cardano-node-pkgs-ng;
              cardano-node = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-node-ng);
              cardano-smash = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-smash-ng);
              cardano-submit-api = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-submit-api-ng);
              cardano-tracer = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.cardano-tracer-ng);
              mithril-client-cli = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.mithril-client-cli-ng);
              mithril-signer = system: flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.mithril-signer-ng);
            };
          };
      };
    in
      (mkGroup "preprod1" "preprod" "preprod-node.${dns}" "preprod1-node.${dns}" false false)
      // (mkGroup "preprod2" "preprod" "preprod-node.${dns}" "preprod2-node.${dns}" false false)
      // (mkGroup "preprod3" "preprod" "preprod-node.${dns}" "preprod3-node.${dns}" false false)
      // (mkGroup "preview1" "preview" "preview-node.${dns}" "preview1-node.${dns}" false false)
      // (mkGroup "preview2" "preview" "preview-node.${dns}" "preview2-node.${dns}" false false)
      // (mkGroup "preview3" "preview" "preview-node.${dns}" "preview3-node.${dns}" false false)
      // (mkGroup "mainnet1" "mainnet" null null false false)
      // (mkGroup "misc1" "preprod" null null false false)
      // (mkGroup "buildkite1" "buildkite" null null false false)
      // (mkGroup "sanchonet1" "sanchonet" "sanchonet-node.${dns}" "sanchonet1-node.${dns}" false false);
  };
}
