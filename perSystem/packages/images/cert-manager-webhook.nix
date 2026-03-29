{
  perSystem = {pkgs, ...}: let
    version = "v1.20.0";

    # Get image digest: docker pull quay.io/jetstack/cert-manager-webhook:v1.20.0 && docker inspect quay.io/jetstack/cert-manager-webhook:v1.20.0 | jq -r '.[0].RepoDigests[0]'
    imageDigest = "sha256:2133daae1f08ad54bcfd317f4a19b48e2bba1c490dbf04e74c4666b3d5d6a69b";
  in {
    packages.cert-manager-webhook-image = pkgs.dockerTools.pullImage {
      imageName = "quay.io/jetstack/cert-manager-webhook";
      inherit imageDigest;
      sha256 = "sha256-zvZAWQ/A6wAeEtM4m7cPze0qlgbR2aVt1LnvrXgxsK4=";
      finalImageName = "cert-manager-webhook";
      finalImageTag = version;
    };
  };
}
