{
  perSystem = {pkgs, ...}: let
    version = "8.2.3-alpine";

    # Get image digest: docker pull public.ecr.aws/docker/library/redis:8.2.3-alpine && docker inspect public.ecr.aws/docker/library/redis:8.2.3-alpine | jq -r '.[0].RepoDigests[0]'
    imageDigest = "sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba";
  in {
    packages.redis-image = pkgs.dockerTools.pullImage {
      imageName = "public.ecr.aws/docker/library/redis";
      inherit imageDigest;
      sha256 = "sha256-zxqnA3nitw2gduEqLdH32yebIdBFsp2YOZRFMxdqTFc=";
      finalImageName = "redis";
      finalImageTag = version;
    };
  };
}
