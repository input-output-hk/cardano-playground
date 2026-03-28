{inputs, ...}: {
  perSystem = {system, ...}: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [
        (_final: prev: {
          # Pin kubectl to 1.34.x to match EKS cluster version (1.34)
          # When upgrading EKS cluster, update version here
          kubectl = prev.kubectl.overrideAttrs (_oldAttrs: rec {
            version = "1.34.5";
            src = prev.fetchFromGitHub {
              owner = "kubernetes";
              repo = "kubernetes";
              rev = "v${version}";
              hash = "sha256-xleHAyasIXAqcS0V5X9Xc8u9TNy0L2gsV2/XjgFcMq0=";
            };
          });

          inplace-image-tag-updater = inputs.inplace-image-tag-updater.packages.${system}.default;
        })
      ];
    };
  };
}
