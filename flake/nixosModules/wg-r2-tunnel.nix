flake: {
  flake.nixosModules.wg-r2-tunnel = {
    name,
    config,
    pkgs,
    ...
  }: let
    inherit (groupCfg) groupName groupFlake;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;
  in {
    environment.systemPackages = [pkgs.wireguard-tools];

    networking = {
      nat = {
        enable = true;
        externalInterface = "ens5";
        internalInterfaces = ["wg0"];
      };

      firewall.allowedUDPPorts = [config.networking.wireguard.interfaces.wg0.listenPort];

      wireguard = {
        enable = true;
        interfaces.wg0 = {
          privateKeyFile = "/run/secrets/wireguard";
          listenPort = 51820;

          # Assign the build machines in the remote farm with their existing
          # wg0 interface assigned IP from the devx-ci repo: "10.100.0.X" where
          # X = the numbered suffix in the name, ex: ci1, ci2, ...
          ips = ["10.254.0.254"];
          peers = [
            # Linux builders
            {
              name = "ci1";
              allowedIPs = ["10.100.0.1/32"];
              publicKey = "52aw4lh3H+x4fXdry2vzZ0yQ/TzmHmG5JTc61/Fu/mM=";
              persistentKeepalive = 25;
            }
            {
              name = "ci2";
              allowedIPs = ["10.100.0.2/32"];
              publicKey = "XF90HyfTTlDJ+8V+L0vRpD/mLYal/6vWUdjXXhauUxQ=";
              persistentKeepalive = 25;
            }
            {
              name = "ci3";
              allowedIPs = ["10.100.0.3/32"];
              publicKey = "SLFctAtZXGCQ8BPfy1aivR7IHXwypjJgTvIXIwKxamY=";
              persistentKeepalive = 25;
            }
            {
              name = "ci4";
              allowedIPs = ["10.100.0.4/32"];
              publicKey = "5B981U7qiMXtuoCfyzY9vyhR953cwcLl6Onx21qPrVo=";
              persistentKeepalive = 25;
            }
            {
              name = "ci5";
              allowedIPs = ["10.100.0.5/32"];
              publicKey = "+ek1olvdILegvVCDCmmUJk+f0N0VQu48Ha4XTyw3Wz0=";
              persistentKeepalive = 25;
            }
            {
              name = "ci6";
              allowedIPs = ["10.100.0.6/32"];
              publicKey = "tSWXADCEKG2yz2Cm4OB6AQRPW22ofuywOYFjfYZt328=";
              persistentKeepalive = 25;
            }
            {
              name = "ci10";
              allowedIPs = ["10.100.0.10/32"];
              publicKey = "izpTUdxSXH17HyhMxl22/BBQThvLl0VpLiF/n/X0lUs=";
              persistentKeepalive = 25;
            }

            # Hydra
            {
              name = "ci9";
              allowedIPs = ["10.100.0.9/32"];
              publicKey = "gGRNt3nw9Dt5Yoi0nK4G81UNeLMGMDw/QuZX6b0kQig=";
              persistentKeepalive = 25;
            }

            # Midnight machines
            {
              name = "ci7";
              allowedIPs = ["10.100.0.7/32"];
              publicKey = "0BMk9CC/fp4Jr0y84BenfaZgwTtLPBR7kX/dRBusiBU=";
              persistentKeepalive = 25;
            }
            {
              name = "ci8";
              allowedIPs = ["10.100.0.8/32"];
              publicKey = "hf7PW+dZzFVowvIGyMO4hm6/UapKVZkTJokjaQLCRjU=";
              persistentKeepalive = 25;
            }
          ];
        };
      };
    };

    sops.secrets = mkSopsSecret {
      secretName = "wireguard";
      keyName = "${name}-wireguard";
      inherit groupOutPath groupName;
      fileOwner = "root";
      fileGroup = "root";
    };
  };
}
