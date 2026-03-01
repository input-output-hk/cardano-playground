{
  inputs,
  config,
  ...
}: {
  perSystem = {system, ...}: {
    packages.ami =
      (inputs.nixpkgs.lib.nixosSystem {
        modules = [
          config.flake.nixosModules.ami
          {nixpkgs.hostPlatform = system;}

          # for sops with KMS
          inputs.cardano-parts.nixosModules.profile-common
          {programs.auth-keys-hub.enable = false;}
        ];
      }).config.system.build.amazonImage;
  };
}
