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
    export LEIOS_PATH_BACKUP="$PATH"
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
