{
  description = "Cardano Playground: cardano testnet clusters";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    cardano-parts.url = "github:input-output-hk/cardano-parts";
    # cardano-parts.url = "path:/home/jlotoski/work/iohk/cardano-parts-wt/cardano-parts";

    # Local pins for additional customization:
    cardano-node-ng.url = "github:input-output-hk/cardano-node/8.3.1-pre";

    # For cardano-node service local debug:
    # cardano-node-service = {
    #   # url = "github:input-output-hk/cardano-node/8.3.1-pre";
    #   url = "path:/home/jlotoski/work/iohk/cardano-node-wt/8.3.1-pre";
    #   flake = false;
    # };
  };

  outputs = inputs: let
    inherit (inputs.cardano-parts.lib) recursiveImports;
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      imports =
        recursiveImports [
          ./flake
          ./perSystem
        ]
        ++ [
          inputs.cardano-parts.flakeModules.aws
          inputs.cardano-parts.flakeModules.cluster
          inputs.cardano-parts.flakeModules.entrypoints
          inputs.cardano-parts.flakeModules.jobs
          inputs.cardano-parts.flakeModules.lib
          inputs.cardano-parts.flakeModules.pkgs
          inputs.cardano-parts.flakeModules.shell
        ];
      systems = ["x86_64-linux"];
      debug = true;
    };

  nixConfig = {
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = "true";
  };
}
