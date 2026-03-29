{
  perSystem = {pkgs, ...}: let
    version = "v1.20.0";

    # Get image digest: docker pull quay.io/jetstack/cert-manager-cainjector:v1.20.0 && docker inspect quay.io/jetstack/cert-manager-cainjector:v1.20.0 | jq -r '.[0].RepoDigests[0]'
    imageDigest = "sha256:6a620381d99583d886e8ce745c872f638bcfc854964ad95d657eec2048a6dca1";
  in {
    packages.cert-manager-cainjector-image = pkgs.dockerTools.pullImage {
      imageName = "quay.io/jetstack/cert-manager-cainjector";
      inherit imageDigest;
      sha256 = "sha256-xq5CyldOK9UGjU6KOK9sa3Zb9VzT64XLvK6Srs6YEtg";
      finalImageName = "cert-manager-cainjector";
      finalImageTag = version;
    };
  };
}
