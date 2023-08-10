{
  description = "Cardano Playground: cardano testnet clusters";

  inputs = {
    auth-keys-hub.url = "github:input-output-hk/auth-keys-hub";
    auth-keys-hub.inputs.nixpkgs.follows = "nixpkgs";
    colmena.url = "github:zhaofengli/colmena/v0.4.0";
    colmena.inputs.nixpkgs.follows = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
    sops-nix.url = "github:Mic92/sops-nix";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    terraform-providers.url = "github:nix-community/nixpkgs-terraform-providers-bin";
    terranix.url = "github:terranix/terranix";

    # Experimental
    # cardano-parts.url = "github:input-output-hk/cardano-parts";
    # cardano-parts.url = "path:/home/jlotoski/work/iohk/cardano-parts-wt/cardano-parts";
  };

  outputs = inputs: let
    inherit ((import ./flake/lib.nix {inherit inputs;}).flake.lib) recursiveImports;
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      imports = recursiveImports [
        ./flake
        ./perSystem
        # inputs.cardano-parts.flakeModules.shell
      ];

      systems = ["x86_64-linux"];
    };

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
      "https://colmena.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "colmena.cachix.org-1:7BzpDnjjH8ki2CT3f6GdOk7QAzPOl+1t3LvTLXqYcSg="
    ];
    allow-import-from-derivation = "true";
  };
}
