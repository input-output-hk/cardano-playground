let
  version = "v0.1.2";
in {
  perSystem = {pkgs, ...}: {
    packages.pinata-go-cli = pkgs.buildGoModule rec {
      inherit version;
      pname = "pinata-go-cli";

      src = pkgs.fetchFromGitHub {
        owner = "PinataCloud";
        repo = "pinata-go-cli";
        rev = version;
        sha256 = "sha256-itGJai5WNHPMO2qkqhS6gGpLd8Y6ImV7uI0waTus/KE=";
      };

      vendorHash = "sha256-3Vi+feg/WeQICEJPmSEYdpVuzZwORINCvoZD4DrRYqY=";

      meta = {
        homepage = "https://github.com/PinataCloud/pinata-go-cli";
        description = "The Pinata CLI written in Go";
      };
    };
  };
}
