flake: {
  flake.nixosModules.profile-metsuke-agent = {
    config,
    lib,
    pkgs,
    name,
    ...
  }: let
    inherit (flake.config.flake.cardano-parts.cluster.infra.aws) domain;
    inherit (groupCfg) groupName groupFlake;
    inherit (opsLib) mkSopsSecret;

    groupOutPath = groupFlake.self.outPath;
    groupCfg = config.cardano-parts.cluster.group;
    opsLib = flake.config.flake.cardano-parts.lib.opsLib pkgs;

    # The CNAME route53.nix-import creates, never the server's host name: an
    # agent's upload_url has to survive the server moving hosts.
    serverName = "metsuke-leios.${domain}";

    # Which pool a producer runs. The generated allowlist says which pools may
    # submit at all, not which host holds which, and the id itself is only on
    # disk sops-encrypted, so this mapping has nowhere else to live.
    poolIds."leios1-bp-a-1" = "pool1kye7409qnlnk2wwnqj5qfr7m0xqns7kk0s09echrnejtud5nred";

    poolId =
      poolIds.${name}
      or (throw "flake/nixosModules/profile-metsuke-agent.nix holds no pool id for ${name}; the agent refuses to start unless its signing key hashes to the configured one.");

    inherit (config.cardano-parts.perNode.meta) cardanoNodePrometheusExporterPort;
    backends = config.services.cardano-node.nodeConfig.TraceOptions."".backends or [];
  in {
    assertions = [
      {
        assertion = lib.any (lib.hasPrefix "PrometheusSimple") backends;
        message = "${name} runs the metsuke agent, but its cardano-node TraceOptions root entry names no PrometheusSimple backend, so nothing listens on ${toString cardanoNodePrometheusExporterPort} to scrape.";
      }
    ];

    # Root-owned rather than service-owned: metsuke runs under DynamicUser, so
    # no service user exists to own it, and systemd reads it as root to hand
    # the agent a credential.
    sops.secrets = mkSopsSecret {
      secretName = "metsuke-cold-skey";
      keyName = "${name}-metsuke-cold.skey";
      inherit groupOutPath groupName name;
      fileOwner = "root";
      fileGroup = "root";
      restartUnits = [config.systemd.services.metsuke.name];
    };

    services.metsuke = {
      enable = true;

      signingKeyFile = config.sops.secrets.metsuke-cold-skey.path;

      settings = {
        pool_id = poolId;
        agent_id = name;
        metrics_url = "http://127.0.0.1:${toString cardanoNodePrometheusExporterPort}/metrics";
        upload_url = "https://${serverName}/v1/submit";
        log.journal_unit = "cardano-node.service";
      };
    };
  };
}
