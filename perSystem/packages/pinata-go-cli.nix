{
  perSystem = {
    lib,
    pkgs,
    ...
  }:
    with lib; {
      packages.pinata-go-cli = pkgs.buildGoModule {
        pname = "pinata-go-cli";
        version = "main";

        src = pkgs.fetchFromGitHub {
          owner = "PinataCloud";
          repo = "pinata-go-cli";
          rev = version;
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
