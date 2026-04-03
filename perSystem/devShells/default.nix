{
  # Uncomment for node service debugging
  # flake.config.cardano-parts.pkgs.special.cardano-node-service = "${flake.inputs.cardano-node-service.outPath}/nix/nixos";

  perSystem = {
    inputs',
    pkgs,
    ...
  }: let
    kustomize-wrapped = pkgs.writeShellScriptBin "kustomize" ''
      exec ${pkgs.kustomize}/bin/kustomize --enable-exec --enable-alpha-plugins "$@"
    '';

    # Override cardano-parts pre-push to include yamlfmt and predictable-yaml checks
    pre-push = pkgs.writeShellApplication {
      name = "pre-push";
      runtimeInputs = with pkgs; [coreutils gitMinimal gnugrep];
      meta.description = "A pre-push repo check for required secrets encryption, linting, formatting, and yaml validation";
      text =
        builtins.replaceStrings
        ["for check in lint treefmt; do"]
        ["for check in lint treefmt yamlfmt predictable-yaml; do"]
        (builtins.readFile "${inputs'.cardano-parts.packages.pre-push}/bin/pre-push");
    };
  in {
    cardano-parts = {
      shell = {
        global = {
          defaultShell = "ops";
          extraPkgs =
            [
              pre-push
              inputs'.predictable-yaml.packages.default
            ]
            ++ (with pkgs; [
              amazon-ecr-credential-helper
              crane
              inplace-image-tag-updater
              kfilt
              kubectl
              kustomize-wrapped
              kustomize-sops
              stern
              yamlfmt
            ]);
          # Override cardano-parts defaultHooks to install our custom pre-push
          defaultHooks = ''
            if [ -d .git/hooks ]; then
              ln -sf ${pre-push}/bin/pre-push .git/hooks/pre-push
            fi
          '';
        };
      };

      # Note that these package config assignments impact not only the devShell which utilize
      # the defined cardano-parts pkgs, but also deployable cluster groups which also may utilize them.
      #
      # Temporarily set all node and cli packages to the X.Y.Z tag
      # pkgs = {
      #   # inherit (flake.inputs.cardanoTest.packages.${system}) cardano-cli cardano-node;
      #   cardano-cli-ng = flake.inputs.cardanoTest.packages.${system}.cardano-cli;
      #   cardano-node-ng = flake.inputs.cardanoTest.packages.${system}.cardano-node;
      #   cardano-tracer-ng = flake.inputs.cardanoTest.packages.${system}.cardano-tracer;
      #   snapshot-converter-ng = flake.inputs.cardanoTest.packages.${system}.snapshot-converter;
      # };
    };
  };
}
