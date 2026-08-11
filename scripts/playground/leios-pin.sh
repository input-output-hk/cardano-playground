#!/usr/bin/env bash

# source this to pin cardano-cli to the leios version
if [ "$1" = "-u" ] && [ ! -z "$LEIOS_PATH_BACKUP" ]; then
  export PATH=$LEIOS_PATH_BACKUP
  unset LEIOS_PATH_BACKUP
else
  if [ -z "$LEIOS_PATH_BACKUP" ]; then
    LEIOS_PIN=$(jq -r '.nodes[.nodes."cardano-node-leios".inputs."cardano-node-leios"].locked | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock)
    mkdir -p ~/.local/bin
    ln -sf "$(nix build -Lv "$LEIOS_PIN#cardano-cli" --no-link --print-out-paths)/bin/cardano-cli" ~/.local/bin/cardano-cli
    ln -sf "$(nix build -Lv "$LEIOS_PIN#cardano-node" --no-link --print-out-paths)/bin/cardano-node" ~/.local/bin/cardano-node
    ln -sf "$(nix build -Lv "$LEIOS_PIN#db-analyser" --no-link --print-out-paths)/bin/db-analyser" ~/.local/bin/db-analyser
    ln -sf "$(nix build -Lv "$LEIOS_PIN#db-synthesizer" --no-link --print-out-paths)/bin/db-synthesizer" ~/.local/db-synthesizer
    ln -sf "$(nix build -Lv "$LEIOS_PIN#db-truncater" --no-link --print-out-paths)/bin/db-truncater" ~/.local/db-truncater
    ln -sf "$(nix build -Lv "$LEIOS_PIN#project.x86_64-linux.hsPkgs.ouroboros-consensus.components.exes.db-immutaliser" --no-link --print-out-paths)/bin/db-immutaliser" ~/.local/bin/db-immutaliser
    export LEIOS_PATH_BACKUP="$PATH"
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
