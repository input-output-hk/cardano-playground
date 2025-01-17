{
  flake.nixosModules.buildkite-nix-nsswitch = {
    nix = {
      settings = {
        # To avoid build problems in containers
        extra-sandbox-paths = ["/etc/nsswitch.conf" "/etc/protocols"];

        # To avoid interactive prompts on flake nix config declarations
        accept-flake-config = true;
      };
    };
  };
}
