{
  description = "Cardano Playground: cardano testnet clusters";

  inputs = {
    nixpkgs.follows = "cardano-parts/nixpkgs";
    nixpkgs-unstable.follows = "cardano-parts/nixpkgs-unstable";
    flake-parts.follows = "cardano-parts/flake-parts";
    cardano-parts.url = "github:input-output-hk/cardano-parts/next-2026-05-15";
    # cardano-parts.url = "path:/home/jlotoski/ai/share/input-output-hk/cardano-parts-wt/next-2026-05-15";

    # PParams api testing
    cardano-node-pparams-api.url = "github:johnalotoski/cardano-node-pparams-api";

    # Extra pins
    cardano-node-leios.url = "github:input-output-hk/ouroboros-leios?ref=refs/tags/prototype-2026w27";
    cardano-node-leios-ghc-debug.url = "github:IntersectMBO/cardano-node/jl/leios-ipe";
    cardano-node-leios-bench.url = "github:IntersectMBO/cardano-node/jl/leios-prototype";
    cardano-db-sync-leios.url = "github:IntersectMBO/cardano-db-sync/jl/leios-prototype";
    cardano-node-11-1-0-rc.url = "github:IntersectMBO/cardano-node/jl/11.1.0-sre";
    iohk-nix-11-1-0-rc.url = "github:input-output-hk/iohk-nix/node-11.1";

    cardano-node-set-iowait.url = "github:IntersectMBO/cardano-node/jl/set-iowait";
  };

  outputs = inputs: let
    inherit (inputs.nixpkgs.lib) mkOption types;
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
          inputs.cardano-parts.flakeModules.process-compose
          inputs.cardano-parts.flakeModules.shell
          {options.flake.opentofu = mkOption {type = types.attrs;};}
        ];
      systems = ["x86_64-linux"];
      debug = true;
    };

  nixConfig = {
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = true;
  };
}
