{
  perSystem = {pkgs, ...}: let
    version = "v3.1.0";

    # Get image digest: docker pull public.ecr.aws/eks/aws-load-balancer-controller:v3.1.0 && docker inspect public.ecr.aws/eks/aws-load-balancer-controller:v3.1.0 | jq -r '.[0].RepoDigests[0]'
    imageDigest = "sha256:9ac20cc2e9f3045ee4d0b64b0b95abd43571229a4d4a5df634054a7f22d02335";
  in {
    packages.aws-load-balancer-controller-image = pkgs.dockerTools.pullImage {
      imageName = "public.ecr.aws/eks/aws-load-balancer-controller";
      inherit imageDigest;
      sha256 = "sha256-RZmESqYAIxL81P29SDTECZEYaV5x0Kr9Atr4OGsg7PA=";
      finalImageName = "aws-load-balancer-controller";
      finalImageTag = version;
    };
  };
}
