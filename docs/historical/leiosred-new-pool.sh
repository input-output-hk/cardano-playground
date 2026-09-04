#! /usr/bin/env bash

# This script was run once for each of the leiosred/PIR pools.
# Only the next two variables need to be adjusted.
group=leiosred1
machine=$group-bp-a-1

if ! [[ -f "static/pools.play.dev.cardano.org/$group.json" ]]; then
  echo 'You have not created the pool metadata JSON yet!'
  exit 1
else
  echo 'Reminder to first deploy misc1-webserver-a-1 with the new pool metadata JSON!'
  echo 'Continuing in 5 seconds...'
  sleep 5s
fi

set -xeuo pipefail

# Basically `scripts/playground/leios-pin.sh` but in the project dir instead of ~/.local/bin, as I preferred that.
LEIOS_PIN=$(jq -r '.nodes[.nodes."cardano-node-leios".inputs."cardano-node-leios"].locked | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock)
mkdir -p .bin
ln -sf "$(nix build -Lv "$LEIOS_PIN#cardano-cli" --no-link --print-out-paths)/bin/cardano-cli" .bin/cardano-cli
ln -sf "$(nix build -Lv "$LEIOS_PIN#cardano-node" --no-link --print-out-paths)/bin/cardano-node" .bin/cardano-node
ln -sf "$(nix build -Lv "$LEIOS_PIN#db-analyser" --no-link --print-out-paths)/bin/db-analyser" .bin/db-analyser
ln -sf "$(nix build -Lv "$LEIOS_PIN#db-synthesizer" --no-link --print-out-paths)/bin/db-synthesizer" .bin/db-synthesizer
ln -sf "$(nix build -Lv "$LEIOS_PIN#db-truncater" --no-link --print-out-paths)/bin/db-truncater" .bin/db-truncater
ln -sf "$(nix build -Lv "$LEIOS_PIN#project.x86_64-linux.hsPkgs.ouroboros-consensus.components.exes.db-immutaliser" --no-link --print-out-paths)/bin/db-immutaliser" .bin/db-immutaliser
export PATH="$PWD/.bin:$PATH"

export DEBUG=true

export CARDANO_NODE_SOCKET_PATH=$PWD/node.socket

export ENV=leios

export POOL_NAMES=$machine
export STAKE_POOL_DIR=secrets/groups/$group

SLOT=$(just query-tip $ENV | jq .slot)
SLOTS_PER_KES_PERIOD=$(jq -r .slotsPerKESPeriod < "docs/environments-pre/$ENV/shelley-genesis.json")
export CURRENT_KES_PERIOD=$((SLOT / SLOTS_PER_KES_PERIOD))

export TESTNET_MAGIC=164
export USE_ENCRYPTION=true
export USE_DECRYPTION=true
export ERA_CMD=dijkstra

export USE_BLS=true

export UNSTABLE=false
export USE_SHELL_BINS=true

nix run .#job-create-stake-pool-keys

POOL_PLEDGE=1000000000 \
POOL_COST=170000000 \
POOL_RELAY="$machine.play.dev.cardano.org" \
POOL_RELAY_PORT=3001 \
PAYMENT_KEY=secrets/envs/$ENV/utxo-keys/rich-utxo \
SUBMIT_TX=false \
POOL_METADATA_BASE_URL="https://pools.play.dev.cardano.org" \
nix run .#job-register-stake-pools

echo 'Now submit the transaction.'

# Delegate the reward stake key to the pool itself so pool rewards compound
# into active stake instead of sitting in an undelegated reward account.
# Run after the registration tx above has confirmed: the certificate needs the
# pool already registered, and both jobs draw a utxo from the same rich key.
PAYMENT_KEY=secrets/envs/$ENV/utxo-keys/rich-utxo \
SUBMIT_TX=false \
nix run .#job-delegate-rewards-stake-key

echo 'Now submit the delegation transaction.'
