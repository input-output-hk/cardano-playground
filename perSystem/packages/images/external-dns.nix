{
  perSystem = {pkgs, ...}: let
    version = "v0.20.0";
  in {
    packages.external-dns-image = pkgs.dockerTools.buildLayeredImage {
      name = "external-dns";
      tag = version;

      contents = with pkgs; [
        cacert
        (buildGoModule rec {
          pname = "external-dns";
          inherit version;

          src = fetchFromGitHub {
            owner = "kubernetes-sigs";
            repo = "external-dns";
            rev = version;
            hash = "sha256-hKmUpRKrefu0nseBc7BKjpvUHVvfLcAnod0kHwW2X14=";
          };

          vendorHash = "sha256-3q2kUO09UBhK8OUpyR4+03tLqpPYc+XYB7iZ9oMenGk=";

          subPackages = ["."];
        })
      ];

      config = {
        Entrypoint = ["/bin/external-dns"];
      };
    };
  };
}
