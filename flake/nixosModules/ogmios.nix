# Ogmios minimal startup code, requiring node to be already imported and configured
{
  flake.nixosModules.ogmios = {config, ...}: {
    services.cardano-ogmios = {
      enable = true;
      package = config.cardano-parts.perNode.pkgs.cardano-ogmios;
      nodeConfig = builtins.toFile "ogmios-node-config.json" (builtins.toJSON config.services.cardano-node.nodeConfig);
      nodeSocket = config.services.cardano-node.socketPath 0;
      hostAddr = "127.0.0.1";
    };

    systemd.services.cardano-ogmios = {
      preStart = ''
        set -uo pipefail
        SOCKET="${config.services.cardano-node.socketPath 0}"

        # Wait for the node socket
        while true; do
          [ -S "$SOCKET" ] && sleep 2 && break
          echo "Waiting for cardano node socket at $SOCKET for 2 seconds..."
          sleep 2
        done
      '';

      serviceConfig = {
        Restart = "always";
        RestartSec = 30;
        User = "cardano-node";
        Group = "cardano-node";
      };
    };
  };
}
