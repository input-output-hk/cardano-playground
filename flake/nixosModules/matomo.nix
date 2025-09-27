flake: {
  flake.nixosModules.matomo = {
    name,
    config,
    pkgs,
    ...
  }: let
    inherit (flake.config.flake.cardano-parts.cluster.infra.aws) domain;
    hostname = "${name}.${domain}";
  in {
    networking.firewall.allowedTCPPorts = [80 443];

    services = {
      matomo = {
        inherit hostname;
        enable = true;
        nginx = {
          serverName = hostname;
          serverAliases = ["matomo.${domain}"];
        };
      };

      mysql = {
        enable = true;
        package = pkgs.mysql84;
      };

      nginx.enable = true;
    };

    security.acme = {
      acceptTerms = true;
      defaults = {
        email = "devops@iohk.io";
        server =
          if true
          then "https://acme-v02.api.letsencrypt.org/directory"
          else "https://acme-staging-v02.api.letsencrypt.org/directory";
      };
    };
  };
}
