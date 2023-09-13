flake: {
  # flake.config.cardano-parts.pkgs.special.cardano-node-service = "${flake.inputs.cardano-node-service.outPath}/nix/nixos";

  perSystem = {system, ...}: {
    cardano-parts.shell.global.defaultShell = "ops";

    # Note that these package config assignments impact not only the devShell which utilize
    # the defined cardano-parts pkgs, but also deployable cluster groups which also may utilize them.
    cardano-parts.pkgs.cardano-cli-ng = flake.inputs.cardano-node-ng.packages.${system}.cardano-cli;
    cardano-parts.pkgs.cardano-node-ng = flake.inputs.cardano-node-ng.packages.${system}.cardano-node;
    cardano-parts.pkgs.cardano-submit-api-ng = flake.inputs.cardano-node-ng.packages.${system}.cardano-submit-api;
  };
}
