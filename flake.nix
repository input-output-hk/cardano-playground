{
  description = "Cardano Playground: cardano testnet clusters";

  inputs = {
    nixpkgs.follows = "cardano-parts/nixpkgs";
    nixpkgs-unstable.follows = "cardano-parts/nixpkgs-unstable";
    flake-parts.follows = "cardano-parts/flake-parts";
    cardano-parts.url = "github:input-output-hk/cardano-parts/next-2025-08-14";
    # cardano-parts.url = "path:/home/jlotoski/work/iohk/cardano-parts-wt/next-2025-08-14";

    # Local pins for additional customization:
    # cardanoTest.url = "github:IntersectMBO/cardano-node/10.5.1";
    # cardanoTest.url = "github:IntersectMBO/cardano-node/ana/10.6-final-integration-mix";
    # cardanoTest.url = "path:/home/jlotoski/work/iohk/cardano-node-wt/ana/10.6-final-integration-mix";

    # cardano-node-js-bang.url = "github:IntersectMBO/cardano-node/js/bang";
    # cardano-node-10-5-1-tmp-profiled-test.url = "github:IntersectMBO/cardano-node/da/10.5.1-tmp-profiled";
    cardano-node-lmdb-test.url = "github:IntersectMBO/cardano-node/da/lmdb-srp-test";
    # cardano-node-lmdb-tmp-profiled-test.url = "github:IntersectMBO/cardano-node/da/lmdb-srp-test-tmp-profiled";
    cardano-node-lmdb-test-traces.url = "github:IntersectMBO/cardano-node/93437a0fb34161f7b6e07334f0760ed670d28b02";
    # cardano-node-lsm-test.url = "github:IntersectMBO/cardano-node/js/lsm-beta";
    # cardano-tracer-prom-test.url = "github:IntersectMBO/cardano-node/...";

    # PParams api testing
    cardano-node-pparams-api.url = "github:johnalotoski/cardano-node-pparams-api";
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
