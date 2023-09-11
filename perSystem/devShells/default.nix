flake: {
  # flake.config.cardano-parts.pkgs.special.cardano-node-service = "${flake.inputs.cardano-node-service.outPath}/nix/nixos";

  perSystem = {system, ...}: {
    cardano-parts.shell.global.defaultShell = "ops";
    cardano-parts.pkgs.cardano-cli-ng = flake.inputs.cardano-node-ng.packages.${system}.cardano-cli;
    cardano-parts.pkgs.cardano-node-ng = flake.inputs.cardano-node-ng.packages.${system}.cardano-node;
    cardano-parts.pkgs.cardano-submit-api-ng = flake.inputs.cardano-node-ng.packages.${system}.cardano-submit-api;
  };
}
