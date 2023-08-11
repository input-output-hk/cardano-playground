flake: {
  perSystem = {config, ...}: {
    config.cardano-parts.shell.defaultShell = "ops";
  };
}
