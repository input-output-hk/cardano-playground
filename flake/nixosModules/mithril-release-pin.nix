# Including the equivalent code directly in flake/colmena.nix as an anonymous import results in infinite recursion
flake @ {
  moduleWithSystem,
  withSystem,
  ...
}: {
  flake.nixosModules.mithril-release-pin = moduleWithSystem ({system}: {lib, ...}: {
    cardano-parts.perNode = {
      pkgs = {
        mithril-client-cli = lib.mkForce (flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.mithril-client-cli));
        mithril-signer = lib.mkForce (flake.withSystem system ({config, ...}: config.cardano-parts.pkgs.mithril-signer));
      };
    };
  });
}
