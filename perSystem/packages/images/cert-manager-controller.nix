{
  perSystem = {pkgs, ...}: let
    version = "v1.20.0";

    # Get image digest: docker pull quay.io/jetstack/cert-manager-controller:v1.20.0 && docker inspect quay.io/jetstack/cert-manager-controller:v1.20.0 | jq -r '.[0].RepoDigests[0]'
    imageDigest = "sha256:b9009aa6b45b59da1363a26dab15aee7d77c7ce01ac2c1cf05ecd1121462db16";
  in {
    packages.cert-manager-controller-image = pkgs.dockerTools.pullImage {
      imageName = "quay.io/jetstack/cert-manager-controller";
      inherit imageDigest;
      sha256 = "sha256-7MNPuqAd+RPQXCOPjYtIjkOVxnDu7mEprcJkfN3y9j4=";
      finalImageName = "cert-manager-controller";
      finalImageTag = version;
    };
  };
}
