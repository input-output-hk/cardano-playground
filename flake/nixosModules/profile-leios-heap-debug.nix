{inputs, ...}: {
  # Opt in per host. The paired node and client must use the same GHC/ghc-debug.
  flake.nixosModules.profile-leios-heap-debug = {
    lib,
    pkgs,
    ...
  }: let
    debugPackages = inputs.cardano-node-leios-ghc-debug.inputs.cardano-node-leios.packages.${pkgs.stdenv.hostPlatform.system};
  in {
    cardano-parts.perNode.pkgs.cardano-node = lib.mkOverride 40 debugPackages.cardano-node-debug;
    environment.systemPackages = [debugPackages.cardano-debug];

    systemd.services.cardano-node.environment.GHC_DEBUG_SOCKET = "/run/cardano-node/ghc-debug.socket";
    services.cardano-node = {
      eventlog = true;
      profiling = "space-info";
      # Keep existing heap/GC tuning. Sample every 30s and flush every 5m;
      # suppress high-volume scheduler events while retaining heap profiles.
      rts_flags_override = lib.mkAfter ["-i30" "-l-agu" "--eventlog-flush-interval=300"];
    };

    # Capture before approaching the memory ceiling: the client caches the
    # heap and pauses the node during capture. Explicit -N1 limits workers.
    # sudo -u cardano-node cardano-debug snapshot \
    #   /var/lib/cardano-node/heap.snapshot \
    #   /run/cardano-node/ghc-debug.socket +RTS -N1 -RTS
    # Archive cardano-node.eventlog and cardano-node.hp before a restart;
    # the service writes them in its state directory unless redirected.
  };
}
