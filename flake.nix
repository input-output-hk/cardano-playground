{
  description = "Cardano Playground: cardano testnet clusters";

  inputs = {
    nixpkgs.follows = "cardano-parts/nixpkgs";
    nixpkgs-unstable.follows = "cardano-parts/nixpkgs-unstable";
    flake-parts.follows = "cardano-parts/flake-parts";
    cardano-parts.url = "github:input-output-hk/cardano-parts/next-2026-05-15";

    # PParams api testing
    cardano-node-pparams-api.url = "github:johnalotoski/cardano-node-pparams-api";

    # Extra pins
    # cardano-node-leios.url = "github:input-output-hk/ouroboros-leios?ref=refs/tags/prototype-2026w35";
    cardano-node-leios.url = "github:input-output-hk/ouroboros-leios/jl/leios-prototype-w35-patched";
    cardano-node-leios-ghc-debug.url = "github:input-output-hk/ouroboros-leios/jl/prototype-debug";
    leios-adversarial-tools = {
      url = "github:input-output-hk/leios-adversarial-tools/nix";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable"; # crane requires at least 26.05
        flake-parts.follows = "flake-parts";
      };
    };

    # Leios observability source: the shared Alloy enrichment modules
    # (demo/proto-devnet/config/alloy-modules/*.alloy) and leios Grafana dashboards
    # (demo/proto-devnet/config/dashboards/*.json).
    leios-observability = {
      # url = "github:input-output-hk/ouroboros-leios";
      # url = "github:input-output-hk/ouroboros-leios?ref=refs/tags/prototype-2026w34";
      url = "github:input-output-hk/ouroboros-leios/jl/leios-prototype-w35-patched";
      flake = false;
    };

    cardano-node-leios-bench.url = "github:IntersectMBO/cardano-node/jl/leios-prototype-2026w32";
    cardano-db-sync-leios.url = "github:IntersectMBO/cardano-db-sync/jl/leios-prototype";
    metsuke.url = "github:input-output-hk/metsuke/jl/updates";
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
