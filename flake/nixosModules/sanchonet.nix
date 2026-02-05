flake: {
  flake.nixosModules.sanchonet = {
    config,
    pkgs,
    lib,
    ...
  }: let
    inherit (builtins) elem fromJSON readFile;
    inherit (lib) filterAttrs;

    # Obtain references to the current upstream cardanoLib regular and pre-release environment libraries
    cardanoLib = flake.config.flake.cardano-parts.pkgs.special.cardanoLib "x86_64-linux";
    cardanoLibNg = flake.config.flake.cardano-parts.pkgs.special.cardanoLibNg "x86_64-linux";

    # Use this list of attrNames to filter the upstream ingested config.
    # This way we can re-create working configs for either legacy or new
    # tracing on sanchonet from just the critical parameters.
    reqAttrs = [
      "AlonzoGenesisHash"
      "ByronGenesisHash"
      "CheckpointsHash"
      "ConsensusMode"
      "ConwayGenesisHash"
      "DijkstraGenesisHash"
      "ExperimentalHardForksEnabled"
      "ExperimentalProtocolsEnabled"
      "LastKnownBlockVersion-Alt"
      "LastKnownBlockVersion-Major"
      "LastKnownBlockVersion-Minor"
      "LedgerDB"
      "MaxKnownMajorProtocolVersion"
      "MinNodeVersion"

      # PeerSharing is auto-configured by node per forge role as of 10.6.x
      # "PeerSharing"

      "Protocol"
      "RequiresNetworkMagic"
      "ShelleyGenesisHash"
      "TestAllegraHardForkAtEpoch"
      "TestAlonzoHardForkAtEpoch"
      "TestMaryHardForkAtEpoch"
      "TestShelleyHardForkAtEpoch"
    ];

    # The upstream provided config file doesn't contain abs paths which nix
    # needs, so this resets them.
    absGenesisPaths = {
      AlonzoGenesisFile = "${flake.self}/docs/environments-tmp/sanchonet/alonzo-genesis.json";
      ByronGenesisFile = "${flake.self}/docs/environments-tmp/sanchonet/byron-genesis.json";
      ConwayGenesisFile = "${flake.self}/docs/environments-tmp/sanchonet/conway-genesis.json";
      ShelleyGenesisFile = "${flake.self}/docs/environments-tmp/sanchonet/shelley-genesis.json";
      DijkstraGenesisFile = "${flake.self}/docs/environments-tmp/sanchonet/dijkstra-genesis.json";
    };

    # Generate the base sanchonet config, stripped of non-essential params
    # and updated with abs paths for genesis files.
    sanchoCfg =
      (filterAttrs (n: _: elem n reqAttrs) (fromJSON
          (readFile "${flake.self}/docs/environments-tmp/sanchonet/config.json")))
      // absGenesisPaths;

    nodeConfig = cardanoLibNg.defaultLogConfig // sanchoCfg;

    # Make an custom sanchonet "environments" attribute consumed by upstream node,
    # tracer, etc, services.
    environments.sanchonet = {
      # The current bootstrap machine or community run sanchonet.
      edgeNodes = [
        {
          addr = "sancho-testnet.able-pool.io";
          port = 6002;
        }
      ];

      # Generate both a nodeConfig and nodeConfigLegacy for new or legacy
      # tracing system.
      inherit nodeConfig;
      nodeConfigLegacy = cardanoLib.defaultLogConfigLegacy // sanchoCfg;

      dbSyncConfig = cardanoLibNg.mkExplorerConfig "sanchonet" nodeConfig // cardanoLibNg.defaultExplorerLogConfig;

      peerSnapshot = fromJSON (readFile "${flake.self}/docs/environments-tmp/sanchonet/peer-snapshot.json");

      useLedgerAfterSlot = 33695977;
    };
  in {
    # Provide the new custom sanchonet enivronments attr set to the
    # appropriate options and services.
    cardano-parts.perNode.lib.cardanoLib.environments = environments;
    services.cardano-tracer.environments = environments;

    # If the legacy tracing system is preferred:
    # services.cardano-node.useLegacyTracing = true;
  };
}
