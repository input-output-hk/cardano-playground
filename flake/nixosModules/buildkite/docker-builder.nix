{
  flake.nixosModules.buildkite-docker-builder = {
    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "daily";
        flags = ["--all" "--force"];
      };
    };

    # Provide dockerhub credentials to buildkite
    systemd.services.buildkite-agent-iohk-setup-docker = {
      wantedBy = ["buildkite-agent-iohk.service"];
      script = ''
        mkdir -p ~buildkite-agent-iohk/.docker
        ln -sf /run/keys/dockerhub-auth ~buildkite-agent-iohk/.docker/config.json
        chown -R buildkite-agent-iohk:buildkite-agent-iohk ~buildkite-agent-iohk/.docker
      '';
      serviceConfig = {
        Type = "oneshot";
      };
    };
  };
}
