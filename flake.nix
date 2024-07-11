{
  description = "Cardano Playground: cardano testnet clusters";

  inputs = {
    nixpkgs.follows = "cardano-parts/nixpkgs";
    nixpkgs-unstable.follows = "cardano-parts/nixpkgs-unstable";
    flake-parts.follows = "cardano-parts/flake-parts";
    cardano-parts.url = "github:input-output-hk/cardano-parts/next-2024-07-03";
    # cardano-parts.url = "path:/home/jlotoski/work/iohk/cardano-parts-wt/next-2024-07-03";

    # Local pins for additional customization:
    cardano-node.url = "github:IntersectMBO/cardano-node/8.1.2";
    cardano-node-821-pre.url = "github:IntersectMBO/cardano-node/8.2.1-pre";
    cardano-node-hd.url = "github:IntersectMBO/cardano-node/utxo-hd-8.2.1";

    # Example of custom node pinning; see dbsync783 in colmena.nix
    # cardano-node-873.url = "github:IntersectMBO/cardano-node/8.7.3";
    # cardano-node-873-service = {
    #   url = "github:IntersectMBO/cardano-node/8.7.3";
    #   flake = false;
    # };
    # iohk-nix-873.url = "github:input-output-hk/iohk-nix/bootstrap-peers-legacy";

    # For node 8.9.4 until dbsync 8.12.1 compatible release is available
    iohk-nix-8-9-4.url = "github:input-output-hk/iohk-nix/jl/release-private-respin";

    # For HD testing
    iohk-nix-legacy.url = "github:input-output-hk/iohk-nix/migrate-to-play-legacy";

    # Voltaire backend swagger ui for private chain deployment
    govtool.url = "github:disassembler/govtool/sl/disable-metadata-validation";
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
