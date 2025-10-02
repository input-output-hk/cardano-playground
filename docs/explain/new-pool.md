# Creating a new pool in playground

In some cases, we may wish to simply add a new pool to an existing network.
This can be accomplished with the cardano-parts nix jobs exposed in the local
as `nix run .#job-*`.

First, create the keys for a new pool.  The parameters available for each job and the
respective job definitions can be found in the cardano-parts repo
`flakeModules/jobs.nix` file.

Example for creating new pool keys:
```bash
# The CURRENT_KES_PERIOD can be calculated from dividing the absolute slot height by slots per kes period:
#   SLOT=$(cardano-cli query tip | jq .slot)
#   SLOTS_PER_KES_PERIOD=$(jq -r .slotsPerKESPeriod < "$PATH_TO/shelley-genesis.json")
#   CURRENT_KES_PERIOD=$(( $SLOT / $SLOTS_PER_KES_PERIOD ))
ENV=sanchonet \
  CURRENT_KES_PERIOD="799" \
  POOL_NAMES="${ENV}1-bp-a-1" \
  STAKE_POOL_DIR=secrets/groups/${ENV}1 \
  TESTNET_MAGIC=4 \
  USE_ENCRYPTION=true \
  USE_DECRYPTION=true \
  ERA_CMD="conway" \
  nix run .#job-create-stake-pool-keys
```

Assuming that a rich key address or equivalent is already available and funded,
set the desired parameters for the pool:
```bash
# Here we turn on debug and set SUBMIT_TX false to review the transaction #
# before submitting it to the network.  Pool metadata was not setup for this
# temporary pool.
ENV="sanchonet" \
  DEBUG="true" \
  POOL_NAMES="${ENV}1-bp-a-1" \
  STAKE_POOL_DIR=secrets/groups/${ENV}1 \
  ERA_CMD="conway" \
  PAYMENT_KEY="secrets/envs/sanchonet/utxo-keys/rich-utxo" \
  POOL_MARGIN="0.2" \
  POOL_PLEDGE="350000000000" \
  POOL_RELAY="$ENV-node.play.dev.cardano.org" \
  POOL_RELAY_PORT="3001" \
  UNSTABLE=false \
  USE_DECRYPTION=true \
  USE_ENCRYPTION=true \
  SUBMIT_TX="false" \
  nix run .#job-register-stake-pools
```

This will register the pool on chain and fund the pledge.  The pool will start
forging blocks as early as the third epoch rollover after registration assuming
sufficient stake.  The delay is required for stake to propagate through the
"mark", "set", "go" phases at which point forging occurs.

Some useful commands to monitor pool stake are:
```bash
POOL_ID=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-pool.id)
POOL_HASH=$(cardano-cli latest query pool-state --stake-pool-id "$POOL_ID" | jq -r 'to_entries[].key')

# Pledge address and rewards payment addresses
OWNER_PAY=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-owner-payment-stake.addr)
REWARD_PAY=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-reward-payment-stake.addr)

# Owner and rewards stake addresses
OWNER_STAKE=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-owner-stake.addr)
REWARD_STAKE=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-reward-stake.addr)

# Verify pledge
cardano-cli latest query utxo --address "$OWNER_PAY"

# Verify pool unspent rewards
cardano-cli latest query stake-address-info --address "$REWARD_STAKE"

# Verify pool state
cardano-cli latest query pool-state --stake-pool-id "$POOL_ID"

# Verify mark, set, go pool and network stake:
cardano-cli latest query stake-snapshot --stake-pool-id "$POOL_ID"

# Show current expected forge fraction for "go":
cardano-cli latest query stake-snapshot --stake-pool-id "$POOL_ID" | jq -r '(.pools | to_entries[].value.stakeGo) / .total.stakeGo * 100'

# Show all delegation to the pool:
cardano-cli latest query spo-stake-distribution --all-spos --output-json | jq ".[] | select(.[0] == \"$POOL_HASH\")"

# Sum all delegation to the pool:
cardano-cli latest query spo-stake-distribution --all-spos --output-json | jq "[.[] | select(.[0] == \"$POOL_HASH\")] | map(.[1]) | add"

# List all network pools:
cardano-cli latest query stake-pools
```

If a custom configured cardano-node needs to be running to facilitate submission to a
custom network defined outside of iohk-nix, the node can be run by setting
appropriate parameters to the `.#run-cardano-node` job as the following example
shows:
```bash
unset ENVIRONMENT
unset UNSTABLE
export DATA_DIR=workbench/sanchonet
export NODE_CONFIG=$(pwd)/docs/environments-tmp/sanchonet/config.json
export NODE_TOPOLOGY=$(pwd)/docs/environments-tmp/sanchonet/topology.json
export SOCKET_PATH=$(pwd)/node-sanchonet.socket
nix run .#run-cardano-node
```

See all configurable `.#run-cardano-node` nix parameters at the cardano-parts
repo in the `flakeModules/entrypoint.nix` file. If preferred, the cardano-node binary can
be directly run from the devShell.
