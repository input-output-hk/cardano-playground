flake: {
  # flake.config.cardano-parts.pkgs.special.cardano-node-service = "${flake.inputs.cardano-node-service.outPath}/nix/nixos";

  perSystem = {system, ...}: {
    cardano-parts.shell.global.defaultShell = "ops";
    # Or any other packages including from local inputs
    # cardano-parts.pkgs.cardano-node = flake.inputs.cardano-parts.inputs.capkgs.packages.${system}.cardano-node-exe-cardano-node-8-1-1-input-output-hk-cardano-node-8-1-1;
    cardano-parts.pkgs.cardano-node = flake.inputs.cardano-node-ng.packages.${system}.cardano-node;
    cardano-parts.pkgs.cardano-cli = flake.inputs.cardano-node-ng.packages.${system}.cardano-cli;
  };
}
