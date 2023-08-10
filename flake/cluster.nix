{
  # Define some cluster-wide configuration.
  # This has to evaluate fast and is imported in various places.
  flake.cluster = rec {
    orgId = "362174735783";
    kms = "arn:aws:kms:${region}:${orgId}:alias/kmsKey";
    region = "eu-central-1";
    profile = "cardano-playground";

    # Set a region to false to set its count to 0 in terraform.
    # After applying once you can remove the line.
    regions = {
      eu-central-1 = true;
    };

    domain = "play.aws.iohkdev.io";
    bucketName = "${profile}-terraform";
  };
}
