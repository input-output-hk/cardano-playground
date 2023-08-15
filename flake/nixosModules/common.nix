{
  self,
  inputs,
  moduleWithSystem,
  ...
}: {
  flake.nixosModules.common = moduleWithSystem ({system}: {config, ...}: {
    imports = [
      inputs.cardano-parts.inputs.sops-nix.nixosModules.default
      inputs.cardano-parts.inputs.auth-keys-hub.nixosModules.auth-keys-hub
    ];

    programs = {
      auth-keys-hub = {
        enable = true;
        package = inputs.cardano-parts.inputs.auth-keys-hub.packages.${system}.auth-keys-hub;
        github = {
          teams = [
            "input-output-hk/node-sre"
          ];

          tokenFile = config.sops.secrets.github-token.path;
        };
      };
    };

    sops.defaultSopsFormat = "binary";

    sops.secrets.github-token = {
      sopsFile = "${self}/secrets/github-token.enc";
      owner = config.programs.auth-keys-hub.user;
      inherit (config.programs.auth-keys-hub) group;
    };
  });
}
