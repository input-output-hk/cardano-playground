{
  config,
  lib,
  withSystem,
  ...
} @ parts:
with builtins;
with lib; {
  flake.hydraJobs = genAttrs config.systems (flip withSystem (
    {
      config,
      pkgs,
      ...
    }: let
      # A sampling of cluster machines to build in CI to validate new work
      # isn't breaking them.
      machineBuildList = [
        # Buildkite
        "buildkite1-eu-central-1-1"

        # Mainnet, PraosMode, edge, relay and bp configs
        "mainnet1-dbsync-a-1"
        "mainnet1-rel-a-1"

        # Preprod, GenesisMode, bp
        "preprod1-bp-a-1"
      ];

      nixosCfgsNoIpModule =
        mapAttrs
        (name: cfg:
          if cfg.config.cardano-parts.perNode.generic.abortOnMissingIpModule
          then
            # Hydra will not have access to "ip-module" IPV4/IPV6 secrets
            # which are ordinarily only accessible from a deployer machine and
            # are not committed. In this case, hydra can still complete a
            # generic build without "ip-module" to check for other breakage.
            cfg.extendModules {
              modules = [
                (_: {
                  cardano-parts.perNode.generic = warn "Building machine ${name} without secret \"ip-module\" inclusion for hydraJobs CI" {
                    abortOnMissingIpModule = false;
                    warnOnMissingIpModule = false;
                  };
                })
              ];
            }
          else cfg)
        (filterAttrs (n: _: elem n machineBuildList) parts.config.flake.nixosConfigurations);

      jobs = {
        nixosConfigurations =
          mapAttrs
          (_: {config, ...}: config.system.build.toplevel)
          nixosCfgsNoIpModule;
        inherit (config) packages checks devShells;
      };
    in
      jobs
      // {
        required = pkgs.releaseTools.aggregate {
          name = "required";
          constituents = collect isDerivation jobs;
        };
      }
  ));
}
