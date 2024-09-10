{
  description = "Cardano Playground: cardano testnet clusters";

  inputs = {
    nixpkgs.follows = "cardano-parts/nixpkgs";
    nixpkgs-unstable.follows = "cardano-parts/nixpkgs-unstable";
    flake-parts.follows = "cardano-parts/flake-parts";
    cardano-parts.url = "github:input-output-hk/cardano-parts/next-2024-09-10";
    # cardano-parts.url = "path:/home/jlotoski/work/iohk/cardano-parts-wt/next-2024-09-10";

    # Local pins for additional customization:
    cardano-node-hd.url = "github:IntersectMBO/cardano-node/utxo-hd-9.0";
    cardano-node-tx-delay.url = "github:IntersectMBO/cardano-node/jl/9.1.0-tx-delay";

    # For node 8.9.4 until dbsync 9.0.0 compatible release is available
    iohk-nix-9-0-0.url = "github:input-output-hk/iohk-nix/577f4d5072945a88dda6f5cfe205e6b4829a0423";

    # Voltaire backend swagger ui for private chain deployment
    govtool.url = "github:disassembler/govtool/sl/disable-metadata-validation";

    # Test updated tracing systems branch with renamed metrics and updated KES values:
    tracingUpdate.url = "github:IntersectMBO/cardano-node/jutaro/metrics_renaming";

    # UTxO-HD testing
    cardano-node-utxo-hd.url = "github:IntersectMBO/cardano-node/utxo-hd-9.1.1";
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
