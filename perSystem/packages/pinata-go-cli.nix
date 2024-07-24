{
  perSystem = {pkgs, ...}: {
    packages.pinata-go-cli = pkgs.buildGoModule rec {
      pname = "pinata-go-cli";
      version = "main-${builtins.substring 0 7 src.rev}";

      src = pkgs.fetchFromGitHub {
        owner = "PinataCloud";
        repo = "pinata-go-cli";
        rev = "d9449601f1f4f184d5325d2e380adcc510bc06cc";
        sha256 = "sha256-tZtKORlDn7EMmLbadRMaOm0CZLXudDdVb+sua3clui4=";
      };

      vendorHash = "sha256-3Vi+feg/WeQICEJPmSEYdpVuzZwORINCvoZD4DrRYqY=";

      meta = {
        homepage = "https://https://github.com/PinataCloud/pinata-go-cli";
        description = "The Pinata CLI written in Go";
      };
    };
  };
}
