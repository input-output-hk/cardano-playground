flake:
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

      domain = "play.aws.iohkdev.io";

      # Preset defaults matched to default terraform rain infra; change if desired:
      # kms = "arn:aws:kms:${region}:${orgId}:alias/kmsKey";
      # bucketName = "${profile}-terraform";
    };

    group = let
      mkGroup = name: environmentName: groupRelayMultivalueDns: isNg: {
        ${name} =
          {
            inherit groupRelayMultivalueDns;
            groupPrefix = "${name}-";
            meta = {inherit environmentName;};
          }
          // optionalAttrs isNg {
            # For the latest genesis only compatible with 8.3.1
            lib.cardanoLib = flake.config.flake.cardano-parts.pkgs.special.cardanoLibNg;

            # Until upstream parts ng has capkgs version, use local flake pins
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
      // (mkGroup "shelley-qa1" "shelley_qa" "shelley-qa.${infra.aws.domain}" true)
      // (mkGroup "shelley-qa2" "shelley_qa" null true)
      // (mkGroup "shelley-qa3" "shelley_qa" null true);
  };
}
