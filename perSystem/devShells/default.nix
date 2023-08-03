flake: {
  perSystem = {
    system,
    lib,
    pkgs,
    config,
    inputs',
    self',
    ...
  }: {
    devShells.default = let
      inherit (flake.config.flake) cluster;
    in
      pkgs.mkShell {
        packages =
          (with pkgs; [
            just
            statix
            wireguard-tools
            nushell
            self'.packages.rain
            self'.packages.terraform
            awscli2
            sops
          ])
          ++ (with inputs'; [
            colmena.packages.colmena
          ]);

        shellHook = ''
          ln -sf ${lib.getExe self'.packages.pre-push} .git/hooks/
          ln -sf ${config.treefmt.build.configFile} treefmt.toml
        '';

        SSH_CONFIG_FILE = ".ssh_config";
        KMS = cluster.kms;
        AWS_REGION = cluster.region;
        AWS_PROFILE = cluster.profile;
      };
  };
}
