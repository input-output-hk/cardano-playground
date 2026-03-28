{
  perSystem = {pkgs, ...}: let
    version = "v3.3.6";

    # Get image digest: docker pull quay.io/argoproj/argocd:v3.3.6 && docker inspect quay.io/argoproj/argocd:v3.3.6 | jq -r '.[0].RepoDigests[0]'
    imageDigest = "sha256:16b92ba472fbb9287459cc52e0ecff07288dff461209955098edb56ce866fe49";
  in {
    packages.argocd-image = pkgs.dockerTools.pullImage {
      imageName = "quay.io/argoproj/argocd";
      inherit imageDigest;
      sha256 = "sha256-1s7JVMT6gsHcvrrZdok4zNoM061o6HgT9fi/htgj7n8=";
      finalImageName = "argocd";
      finalImageTag = version;
    };
  };
}
