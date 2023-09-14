{self, ...}: {
  flake.nixosModules.common = {config, ...}: {
    programs.auth-keys-hub.github = {
      teams = [
        "input-output-hk/node-sre"
      ];

      tokenFile = config.sops.secrets.github-token.path;
    };

    sops.secrets.github-token = {
      sopsFile = "${self}/secrets/github-token.enc";
      owner = config.programs.auth-keys-hub.user;
      inherit (config.programs.auth-keys-hub) group;
    };
  };
}
