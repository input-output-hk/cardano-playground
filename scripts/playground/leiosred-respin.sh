#!/usr/bin/env bash

# Run this for registering all 10 piranha pools with the same keys as
# originally registered.
#
# NOTE that {owner,reward}-payment-stake.addr files may
# change if RICH_KEY has changed on respin

. scripts/bash-fns.sh
. scripts/playground/leios-pin.sh

export CURRENT_KES_PERIOD=0
export DEBUG=true
export ENV=leios
export ERA_CMD=dijkstra
export PAYMENT_KEY=secrets/envs/$ENV/utxo-keys/rich-utxo
export POOL_COST=170000000
export POOL_METADATA_BASE_URL="https://pools.play.dev.cardano.org"
export POOL_PLEDGE=1000000000
export POOL_RELAY_PORT=3001
export SUBMIT_TX=false
export TESTNET_MAGIC=164
export UNSTABLE=false
export USE_BLS=true
export USE_DECRYPTION=true
export USE_ENCRYPTION=true
export USE_SHELL_BINS=true

for i in "leiosred1 a" "leiosred2 b" "leiosred3 c" "leiosred4 d" "leiosred5 e" "leiosred6 f" "leiosred7 g" "leiosred8 h" "leiosred9 i" "leiosred10 j"; do
  group=$(echo "$i" | awk -d' ' '{print $1}')
  region=$(echo "$i" | awk -d' ' '{print $2}')
  machine="$group-bp-$region-1"

  export STAKE_POOL_DIR="secrets/groups/$group"
  export POOL_NAMES="$machine"

  echo "Registering and delegating to pool: $machine"
    POOL_RELAY="$machine.play.dev.cardano.org" \
    nix run .#job-register-stake-pools

  echo
  echo "Review the registration transaction:"
  cardano-cli debug transaction view --tx-file "$machine-tx-pool-reg.txsigned"
  echo
  read -n 1 -srp "Press a char to continue, or hit CTRL-C"
  echo
  cardano-cli dijkstra transaction submit --tx-file "$machine-tx-pool-reg.txsigned"
  wait-for-mempool

  nix run .#job-delegate-rewards-stake-key

  echo
  echo "Review the delegation transaction:"
  cardano-cli debug transaction view --tx-file "$machine-tx-pool-deleg.txsigned"
  echo
  read -n 1 -srp "Press a char to continue, or hit CTRL-C"
  echo
  cardano-cli dijkstra transaction submit --tx-file "$machine-tx-pool-deleg.txsigned"
  wait-for-mempool
done
