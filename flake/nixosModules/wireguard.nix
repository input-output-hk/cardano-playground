{self, ...}: {
  flake.nixosModules.wireguard = {
    name,
    config,
    ...
  }: {
    sops.secrets.wg.sopsFile = "${self}/secrets/wireguard_${name}.enc";

    systemd.services.wireguard-wg0 = {
      after = ["sops-nix.service"];
      serviceConfig.SupplementaryGroups = [config.users.groups.keys.name];
      # unitConfig.ConditionPathExists = config.sops.secrets.wg.path;
    };

    networking = {
      nat = {
        enable = true;
        externalInterface = "ens5";
        internalInterfaces = ["wg0"];
      };

      firewall = {
        allowedUDPPorts = [config.networking.wireguard.interfaces.wg0.listenPort];
        interfaces.wg0.allowedTCPPorts = [22];
      };

      wireguard = {
        enable = true;

        interfaces.wg0 = {
          privateKeyFile = config.sops.secrets.wg.path;
          listenPort = 51820;
        };
      };
    };
  };
}
