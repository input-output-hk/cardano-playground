{
  # Uncomment for node service debugging
  # flake.config.cardano-parts.pkgs.special.cardano-node-service = "${flake.inputs.cardano-node-service.outPath}/nix/nixos";

  perSystem = {
    inputs',
    # system,
    ...
  }: {
    cardano-parts = {
      shell.global = {
        defaultShell = "ops";
        extraPkgs = [inputs'.cardano-parts.packages.pre-push];
      };

      # Note that these package config assignments impact not only the devShell which utilize
      # the defined cardano-parts pkgs, but also deployable cluster groups which also may utilize them.
      #
      # Temporarily set all node and cli packages to the X.Y.Z tag
      # pkgs = {
      #   inherit (flake.inputs.cardano-node-ng.packages.${system}) cardano-cli cardano-node;
      #   cardano-cli-ng = flake.inputs.cardano-node-ng.packages.${system}.cardano-cli;
      #   cardano-node-ng = flake.inputs.cardano-node-ng.packages.${system}.cardano-node;
      # };
    };
  };
}
