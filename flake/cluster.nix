flake: {
  # Define some cluster-wide configuration.
  # This has to evaluate fast and is imported in various places.
  flake.cardano-parts.cluster = {
    infra.aws = {
      orgId = "362174735783";
      region = "eu-central-1";
      profile = "cardano-playground";

      # Set a region to false to set its count to 0 in terraform.
      # After applying once you can remove the line.
      regions = {
        ap-southeast-1 = true;
        eu-central-1 = true;
        eu-west-1 = true;
        us-east-2 = true;
      };

      domain = "play.aws.iohkdev.io";

      # Preset defaults matched to default terraform rain infra; change if desired:
      # kms = "arn:aws:kms:${region}:${orgId}:alias/kmsKey";
      # bucketName = "${profile}-terraform";
    };

    group = {
      preprod = {
        groupPrefix = "preprod-";
        meta.environmentName = "preprod";
      };

      preview = {
        groupPrefix = "preview-";
        meta.environmentName = "preview";
      };

      sanchonet = {
        groupPrefix = "sanchonet-";
        meta.environmentName = "sanchonet";

        # For the latest genesis only compatible with 8.3.1
        lib.cardanoLib = flake.config.flake.cardano-parts.pkgs.special.cardanoLibNg;

        # Until upstream parts ng has capkgs version, use local flake pins
        pkgs.cardano-node-pkgs = flake.config.flake.cardano-parts.pkgs.special.cardano-node-pkgs-ng;
      };
    };
  };
}
