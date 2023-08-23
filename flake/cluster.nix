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

    group.default = {
      groupPrefix = "play-";
      meta = {
        environmentName = "sanchonet";
      };
    };
  };
}
