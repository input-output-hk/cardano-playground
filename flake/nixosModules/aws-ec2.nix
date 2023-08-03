{inputs, ...}: {
  flake.nixosModules.aws-ec2 = {lib, ...}: {
    imports = [
      "${inputs.nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
    ];

    options = {
      aws = lib.mkOption {
        default = null;
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            region = lib.mkOption {
              type = lib.types.str;
            };

            instance = lib.mkOption {
              type = lib.types.anything;
            };

            route53 = lib.mkOption {
              default = null;
              type = lib.types.nullOr lib.types.anything;
            };
          };

          config = {
            instance.count = lib.mkDefault 1;
          };
        });
      };
    };
  };
}
