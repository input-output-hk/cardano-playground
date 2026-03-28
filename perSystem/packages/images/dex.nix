{
  perSystem = {pkgs, ...}: let
    version = "v2.43.0";

    # Get image digest: docker pull ghcr.io/dexidp/dex:v2.43.0 && docker inspect ghcr.io/dexidp/dex:v2.43.0 | jq -r '.[0].RepoDigests[0]'
    imageDigest = "sha256:b08a58c9731c693b8db02154d7afda798e1888dc76db30d34c4a0d0b8a26d913";
  in {
    packages.dex-image = pkgs.dockerTools.pullImage {
      imageName = "ghcr.io/dexidp/dex";
      inherit imageDigest;
      sha256 = "sha256-doMDCjF8Npl5XIEEmV98iBV5hySLR0CUV6KWlhdOZC8=";
      finalImageName = "dex";
      finalImageTag = version;
    };
  };
}
