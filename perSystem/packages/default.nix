{
  imports = [
    ./pre-push
  ];

  perSystem = {
    inputs',
    pkgs,
    ...
  }: {
    packages = {
      inherit (inputs'.nixpkgs-unstable.legacyPackages) rain;

      terraform = let
        inherit
          (inputs'.terraform-providers.legacyPackages.providers)
          hashicorp
          loafoe
          ;
      in
        pkgs.terraform.withPlugins (_: [
          hashicorp.aws
          hashicorp.external
          hashicorp.local
          hashicorp.null
          hashicorp.tls
          loafoe.ssh
        ]);
    };
  };
}
