flake @ {self, ...}: {
  flake.nixosModules.common = {
    config,
    lib,
    ...
  }: let
    inherit (builtins) toJSON;
    inherit (lib) escapeShellArg;

    inherit (flake.config.flake.cardano-parts.cluster.infra.generic) project;
  in {
    programs.auth-keys-hub.github = {
      teams = ["input-output-hk/node-sre"];

      # Avoid loss of access edge cases when only github teams used for authorized key access
      # Edge case example:
      #   * Auth-keys-hub state defaults to the /run ephemeral state dir or subdirs
      #   * Only a github team is declared for auth-keys-hub access, and assume the github token secret is non-ephemeral
      #   * Another user deletes deletes the github token from github
      #   * The machine is rebooted
      #   * Auth keys hub state is now gone and the github token is required to pull new authorized key state, but it's no longer valid
      #   * Machine lockout occurs
      #
      # NOTE: auth-keys-hub update is required to support individual users when team fetch fails due to invalid or missing github token
      users = ["johnalotoski" "snarlysodboxer"];

      tokenFile = config.sops.secrets.github-token.path;
    };

    # Protect against remaining loss of access edge cases and black swan events
    # Edge case examples:
    #   a) Auth keys hub is deployed as the sole source of authorized keys
    #      * Auth keys hub is updated and a bug is introduced which expresses later on, causing machine lockout
    #   b) Auth keys hub is deployed as the sole source of authorized keys
    #      * Later, auth-keys-hub is removed from the deployment, but adding additional authorized_keys was forgotten
    #      * Machine lockout occurs
    #   c) Solar flare EMP knocking out a large number of machines over a large geographic area for some period of time
    #      * Github api is not available to pull fresh authorized key state and the ephermal storage was lost during reboot
    #      * Machine lockout occurs
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEsOGfoqcopR+FTFTGAe3HfetABmSEjRDj8cyZHbPBa david.amick@iohk.io"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCogRPMTKyOIQcbS/DqbYijPrreltBHf5ctqFOVAlehvpj8enEE51VSjj4Xs/JEsPWpOJL7Ldp6lDNgFzyuL2AOUWE7wlHx2HrfeCOVkPEzC3uL4OjRTCdsNoleM3Ny2/Qxb0eX2SPoSsEGvpwvTMfUapEa1Ak7Gf39voTYOucoM/lIB/P7MKYkEYiaYaZBcTwjxZa3E+v7At4umSZzv8x24NV60fAyyYmt5hVZRYgoMW+nTU4J/Oq9JGgY7o+WPsOWcgFoSretRnGDwjM1IAUFVpI45rQH2HTKNJ6Bp6ncKwtVaP2dvPdBFe3x2LLEhmh1jDwmbtSXfoVZxbONtub2i/D8DuDhLUNBx/ROgal7N2RgYPcPuNdzfp8hMPjPGZVcSmszC/J1Gz5LqLfWbKKKti4NiSX+euy+aYlgW8zQlUS7aGxzRC/JSgk2KJynFEKJjhj7L9KzsE8ysIgggxYdk18ozDxz2FMPMV5PD1+8x4anWyfda6WR8CXfHlshTwhe+BkgSbsYNe6wZRDGqL2no/PY+GTYRNLgzN721Nv99htIccJoOxeTcs329CppqRNFeDeJkGOnJGc41ze+eVNUkYxOP0O+pNwT7zNDKwRwBnT44F0nNwRByzj2z8i6/deNPmu2sd9IZie8KCygqFiqZ8LjlWTD6JAXPKtTo5GHNQ== john.lotoski@iohk.io"
    ];

    sops.secrets.github-token = {
      sopsFile = "${self}/secrets/github-token.enc";
      owner = config.programs.auth-keys-hub.user;
      inherit (config.programs.auth-keys-hub) group;
    };

    system.systemBuilderCommands = ''
      printf '%s' ${
        escapeShellArg (toJSON ((removeAttrs self.sourceInfo ["outPath"]) // {outPathStr = self.sourceInfo.outPath;}))
      } > $out/source-info-${project}.json
    '';
  };
}
