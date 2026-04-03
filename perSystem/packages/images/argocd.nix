{
  perSystem = {pkgs, ...}: let
    version = "v3.3.6";

    # Get image digest: docker pull quay.io/argoproj/argocd:v3.3.6 && docker inspect quay.io/argoproj/argocd:v3.3.6 | jq -r '.[0].RepoDigests[0]'
    imageDigest = "sha256:16b92ba472fbb9287459cc52e0ecff07288dff461209955098edb56ce866fe49";

    baseImage = pkgs.dockerTools.pullImage {
      imageName = "quay.io/argoproj/argocd";
      inherit imageDigest;
      sha256 = "sha256-1s7JVMT6gsHcvrrZdok4zNoM061o6HgT9fi/htgj7n8=";
      finalImageName = "argocd";
      finalImageTag = version;
    };
  in {
    packages.argocd-image = pkgs.dockerTools.buildImage {
      name = "argocd";
      tag = version;
      fromImage = baseImage;

      # Copy static versions of binaries to ensure they exist and are the right versions.
      # This avoids breaking existing dynamic linking in the base image,
      #   which happened when we tried to use various combinations of
      #   the dynamically linked versions and buildLayeredImage.
      copyToRoot = pkgs.runCommand "argocd-tools" {} ''
        mkdir -p $out/usr/local/bin
        cp ${pkgs.pkgsStatic.kustomize}/bin/kustomize $out/usr/local/bin/kustomize
        cp ${pkgs.pkgsStatic.kustomize-sops}/bin/ksops $out/usr/local/bin/ksops
        cp ${pkgs.pkgsStatic.sops}/bin/sops $out/usr/local/bin/sops
        cp ${pkgs.pkgsStatic.age}/bin/age $out/usr/local/bin/age
        chmod +x $out/usr/local/bin/*
      '';

      config = {
        User = "999";
        Env = [
          # This path is coupled to the mount point in the Deployment.
          "SOPS_AGE_KEY_FILE=/app/config/age/argocd-key.txt"
        ];
      };
    };
  };
}
