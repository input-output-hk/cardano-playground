#!/usr/bin/env bash
# shellcheck disable=SC2031,SC2317,SC2155,SC2139

# This script is meant more as a guide than an actual straight executable.
# It requires interactivity with node starts, stops, block synthesis and time feedback.

# Source bash helper functions
source scripts/bash-fns.sh

# Basic cardano environment setup vars and bins:
export USE_SHELL_BINS="true"
LEIOS_PIN=$(jq -r '.nodes[.nodes."cardano-node-leios".inputs."cardano-node-leios"].locked | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock)
alias cardano-node="$(nix build -Lv "$LEIOS_PIN#cardano-node" --no-link --print-out-paths)/bin/cardano-node"
alias cardano-cli="$(nix build -Lv "$LEIOS_PIN#cardano-cli" --no-link --print-out-paths)/bin/cardano-cli"
alias db-analyser="$(nix build -Lv "$LEIOS_PIN#db-analyser" --no-link --print-out-paths)/bin/db-analyser"
alias db-immutaliser="$(nix build -Lv "$LEIOS_PIN#project.x86_64-linux.hsPkgs.ouroboros-consensus.components.exes.db-immutaliser" --no-link --print-out-paths)/bin/db-immutaliser"
alias db-synthesizer="$(nix build -Lv "$LEIOS_PIN#db-synthesizer" --no-link --print-out-paths)/bin/db-synthesizer"
alias db-truncater="$(nix build -Lv "$LEIOS_PIN#db-truncater" --no-link --print-out-paths)/bin/db-truncater"

# So that the custom cardano-cli passes through to the nix jobs when USE_SHELL_BINS is in use -- aliases won't resolve
mkdir -p ~/.local/bin
ln -sf "$(nix build -Lv "$LEIOS_PIN#cardano-cli" --no-link --print-out-paths)/bin/cardano-cli" ~/.local/bin/cardano-cli
export PATH_BACKUP="$PATH"
export PATH="$HOME/.local/bin:$PATH"

# Alias the pre-release bins as well to ensure consistent bin usage
alias cardano-node-ng=cardano-node
alias cardano-cli-ng=cardano-cli
alias db-analyser-ng=db-analyser
alias db-analyser-ng=db-immutaliser
alias db-synthesizer-ng=db-synthesizer
alias db-truncater-ng=db-truncater

# Expect leios currently at ~11.0.1
cardano-node --version
cardano-node-ng --version

# Expect leios currently at ~11.0.0.0
cardano-cli --version
cardano-cli-ng --version

export DEBUG="true"

export ENV="leios"
export UNSTABLE="false"
export UNSTABLE_LIB="false"
export CARDANO_NODE_NETWORK_ID="164"
export TESTNET_MAGIC="164"
export USE_NODE_CONFIG_BP="false"
export NUM_GENESIS_KEYS="3"
export NUM_CC_KEYS="3"
# Security param:
#   432 for 1 day epoch
#    32 for 2 hr epoch
export SECURITY_PARAM="432"
export SLOT_LENGTH="1000"
export START_TIME="2026-05-29T00:00:00Z"
export IPFS_GATEWAY_URI="https://ipfs.io"
export USE_GUARDRAILS="true"
export ERA_CMD=conway

# The node config *must* reflect this PV with appropriate
# `"Test${ERA}HardForkAtEpoch": 0,` up to and including the era's protocol
# version declared here.
export PROTOCOL_VERSION_MAJOR="11"
export PROTOCOL_VERSION_MINOR="0"

# Basic job directory setup vars:
export GENESIS_DIR="workbench/custom"
export DATA_DIR="$GENESIS_DIR/rundir"
export KEY_DIR="$GENESIS_DIR/envs/$ENV"
export CARDANO_NODE_SOCKET_PATH="$DATA_DIR/node.socket"

# Basic pool setup vars:
export CURRENT_KES_PERIOD="0"
export POOL_MARGIN="1.0"
export POOL_RELAY="$ENV-node.play.dev.cardano.org"
export POOL_RELAY_PORT="3001"
# For now, faucet will be:
#   10000200000 lovelace (10k ADA) funding utxos @ 5000 count,
#   1000000000000 (1M ADA) Pool delegation,
#   10000000 (10 ADA) delegation UTxO @ 100 count
# For stability, our pool pledge will be 10M ADA
export POOL_PLEDGE="10000000000000"

# Basic secrets setup vars:
export BULK_CREDS="$GENESIS_DIR/bulk.creds.all.json"
export CC_DIR="$KEY_DIR/cc-keys"
export DREP_DIR="$KEY_DIR/drep"
export PAYMENT_KEY="$KEY_DIR/utxo-keys/rich-utxo"
export USE_ENCRYPTION="false"
export USE_DECRYPTION="false"

# Modified vars from default values specific to the new network:
export DREP_DEPOSIT="500000000"
export GOV_ACTION_DEPOSIT="100000000000"
export VOTING_POWER="1000000000000"

# Conway constitution specifics for genesis file embedding
# Use a final constitution copy from mainnet to indicate when we are no longer using an interim constitution.
export SCRIPT_FILE_URL="https://book.play.dev.cardano.org/environments/preview/guardrails-script.plutus"
export CONSTITUTION_ANCHOR_DATAHASH="2a61e2f4b63442978140c77a70daab3961b22b12b63b13949a390c097214d1c5"
export CONSTITUTION_ANCHOR_URL="ipfs://bafkreiazhhawe7sjwuthcfgl3mmv2swec7sukvclu3oli7qdyz4uhhuvmy"
export CONSTITUTION_SCRIPT="fa24fb305126805cf2164c161d852a0e7330cf988f1fe558cf7d4a64"

# New Leios required env vars:
# The old leios at 10.5.1 glibc required faketime adjustment.
# The new leios remake at 11.0.1 does not require faketime glibc adjustment.
# export FAKETIME_FLAKE="github:nixos/nixpkgs/nixos-23.05"
#
# TODO: Add this to the node cfg file -- this is now a noop
# export LEIOS_DB_PATH="$DATA_DIR/leios.db"

# Leios is now rebased on 11.0.1 so taking the latest testnet-template is
# ideal. Even when previously using the old 10.5.1 Leios, taking the latest
# testnet template and patching back for older versions was still the easiest
# approach to a working deployment.
export TEMPLATE_DIR="$(nix eval --raw --impure --expr "let f = builtins.getFlake \"github:input-output-hk/iohk-nix\"; in f.outPath")/cardano-lib/testnet-template"

# Per the comment above, we'll use the pre-release node binary to generate
# genesis config, and then use the leios node version for the remainder of the
# commands.
USE_SHELL_BINS="" \
  UNSTABLE="true" \
  UNSTABLE_LIBS="true" \
  nix run .#job-gen-custom-node-config-data-ng

# Create the network backbone pools
POOL_NAMES="${ENV}1-bp-a-1" \
STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}1" \
nix run .#job-create-stake-pool-keys

POOL_NAMES="${ENV}2-bp-b-1" \
STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}2" \
nix run .#job-create-stake-pool-keys

POOL_NAMES="${ENV}3-bp-c-1" \
STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}3" \
nix run .#job-create-stake-pool-keys

BOOTSTRAP_CREDS=$(cat "$KEY_DIR"/bootstrap-pool/bulk.creds.bootstrap.json)
(
  jq -r '.[]' <<< "$BOOTSTRAP_CREDS"
  jq -r '.[]' <<< "$(cat "$GENESIS_DIR/groups/${ENV}1/no-deploy/bulk.creds.pools.json")"
  jq -r '.[]' <<< "$(cat "$GENESIS_DIR/groups/${ENV}2/no-deploy/bulk.creds.pools.json")"
  jq -r '.[]' <<< "$(cat "$GENESIS_DIR/groups/${ENV}3/no-deploy/bulk.creds.pools.json")"
) | jq -s > "$BULK_CREDS"

# This is to adjust the starting conway genesis to match preview closely
# without having to parameterize the nix job-gen-custom-node-config-data-ng
# helper extensively. Our starting genesis is still customized slightly with
# committeeMinSize at 3 and committeeMaxTerm length at the guardrails maximum.
jq -S '. += {
  "govActionDeposit": 100000000000,
  "minFeeRefScriptCostPerByte": 15,
  "poolVotingThresholds": {
    "committeeNoConfidence": 0.51,
    "committeeNormal": 0.51,
    "hardForkInitiation": 0.51,
    "motionNoConfidence": 0.51,
    "ppSecurityGroup": 0.51
  }
}' < "$DATA_DIR/conway-genesis.json" | sponge "$DATA_DIR/conway-genesis.json"

# Adjust shelley genesis to set minPoolCost and maxBlockBodySize to current
# network standards.
jq -S '.protocolParams += {
  "minPoolCost": 170000000,
  "maxBlockBodySize": 90112
}' < "$DATA_DIR/shelley-genesis.json" | sponge "$DATA_DIR/shelley-genesis.json"

# Adjust alonzo genesis to include to set execution unit limits and cost models
# to van Rossem network standard.
#
# TODO: Investigate this -- it should create a cost model the way we want directly, ie: van Rossem, but it doesn't
# jq -S --slurpfile costModels scripts/cost-models/vanrossem-parameters-pv11-prep.json '. += {
#   "maxBlockExUnits": {
#     "exUnitsMem": 72000000,
#     "exUnitsSteps": 20000000000
#   },
#   "maxTxExUnits": {
#     "exUnitsMem": 16500000,
#     "exUnitsSteps": 10000000000
#   }
# }
# | .extraConfig.costModels = $costModels[0]' < "$DATA_DIR/alonzo-genesis.json" | sponge "$DATA_DIR/alonzo-genesis.json"

# The old fashioned way -- don't worry about the cost model until we submit on-chain gov action
# Adjust alonzo genesis to set execution unit limits and cost models closer to mainnet
jq -S '. += {
   "maxBlockExUnits": {
     "exUnitsMem": 72000000,
     "exUnitsSteps": 20000000000
   },
   "maxTxExUnits": {
     "exUnitsMem": 16500000,
     "exUnitsSteps": 10000000000
   }
}' < "$DATA_DIR/alonzo-genesis.json" | sponge "$DATA_DIR/alonzo-genesis.json"

# Shim the node config as needed.
# This will require:
#   - Add leios specific config and tracing options
#   - Snapshot interval is generally good at 40*k
#
# If forking directly to Dijkstra, the following will need to be added:
#   - | .TestDijkstraHardForkAtEpoch = 0
#
jq -S '.ExperimentalHardForksEnabled = true
  | .MempoolCapacityBytesOverride = 25000000
  | .LedgerDB *= {
      SnapshotInterval: 864
    }
  | .TraceOptions *= {
      "Consensus.LeiosKernel": {"maxFrequency": 0, "severity": "Debug"},
      "Consensus.LeiosPeer": {"maxFrequency": 0, "severity": "Debug"},
      "LeiosFetch.Remote": {"maxFrequency": 0, "severity": "Debug"},
      "LeiosNotify.Remote": {"maxFrequency": 0, "severity": "Debug"}
    }' \
  "$DATA_DIR/node-config.json" \
  | sponge "$DATA_DIR/node-config.json"

# Update genesis hashes in node config after modifying the genesis files.
HASH_CONWAY=$(cardano-cli latest genesis hash --genesis "$DATA_DIR/conway-genesis.json")
HASH_SHELLEY=$(cardano-cli latest genesis hash --genesis "$DATA_DIR/shelley-genesis.json")
HASH_ALONZO=$(cardano-cli latest genesis hash --genesis "$DATA_DIR/alonzo-genesis.json")
jq --sort-keys \
  --arg hashConway "$HASH_CONWAY" \
  --arg hashShelley "$HASH_SHELLEY" \
  --arg hashAlonzo "$HASH_ALONZO" \
  '. += {
    ConwayGenesisHash: $hashConway,
    ShelleyGenesisHash: $hashShelley,
    AlonzoGenesisHash: $hashAlonzo,
  }' \
  < "$DATA_DIR/node-config.json" \
  | sponge "$DATA_DIR/node-config.json"

# At this point interactivity will be required.
# This script will exit and the remainder can be executed interactivity using
# the following as a guide.
exit 0

# Start the node 30 seconds before the chain is scheduled to start forging.
# Note that if you run older versions of node, the libfaketime will need to
# match the glibc version.
run-node-faketime "$(date -u -d "$START_TIME - 30 seconds" "+%Y-%m-%dT%H:%M:%SZ")"

# Continue operations in another shell window.
# Source the same bash helper functions given above in the new window.
# Export all the same env vars given above in the new window.

# Note: This defaults to 10M ADA pool pledge; see note above
echo "Registering stake pools..."
POOL_NAMES="${ENV}1-bp-a-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}1" \
  ERA_CMD="alonzo" \
  nix run .#job-register-stake-pools
wait-for-mempool

POOL_NAMES="${ENV}1-bp-a-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}1" \
  ERA_CMD="alonzo" \
  nix run .#job-delegate-rewards-stake-key
wait-for-mempool

POOL_NAMES="${ENV}2-bp-b-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}2" \
  ERA_CMD="alonzo" \
  nix run .#job-register-stake-pools
wait-for-mempool

POOL_NAMES="${ENV}2-bp-b-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}2" \
  ERA_CMD="alonzo" \
  nix run .#job-delegate-rewards-stake-key
wait-for-mempool

POOL_NAMES="${ENV}3-bp-c-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}3" \
  ERA_CMD="alonzo" \
  nix run .#job-register-stake-pools
wait-for-mempool

POOL_NAMES="${ENV}3-bp-c-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}3" \
  ERA_CMD="alonzo" \
  nix run .#job-delegate-rewards-stake-key
wait-for-mempool

# Retire the bootstrap pool.
#
# If the bootstrap pool is not retired, an extra UTxO will need to be sent to the
# rich address for collateral UTxO input in subsequent Txs.  Also, some quirky
# behavior was noted with genesis embedded pools in prior node versions.  By
# retiring the bootstrap pool and keeping the new backbone pools as the primary
# forgers, we avoid any residual unexpected edge cases.
BOOTSTRAP_POOL_DIR="$KEY_DIR/bootstrap-pool" \
  RICH_KEY="$KEY_DIR/utxo-keys/rich-utxo" \
  nix run .#job-retire-bootstrap-pool
wait-for-mempool

# Authorize the constitutional committee hot keys
for i in $(seq 1 "$NUM_CC_KEYS"); do
  echo "Authorizing CC$i member's hot credentials..."
  INDEX="$i" \
    nix run .#job-register-cc
  wait-for-mempool
  echo
done

echo "Creating and registering drep-0"
export POOL_DELEG_ID=$(cat "$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-pool.id")
INDEX="0" \
  STAKE_DEPOSIT="2000000" \
  nix run .#job-register-drep
wait-for-mempool

# If both cost model and hard fork proposal are submitted in the same
# epoch, the cost model will fail to take effect.  We'll delay submission of
# any HF proposal by one epoch to allow for ratification of the cost model
# first.
echo "Submitting a cost model governance action..."
PROPOSAL_ARGS=("--cost-model-file" "scripts/cost-models/vanrossem-parameters-pv11-prep.json")
ACTION="create-protocol-parameters-update" \
  STAKE_KEY="$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-stake" \
  nix run .#job-submit-gov-action -- "${PROPOSAL_ARGS[@]}"
wait-for-mempool

# NOTE:
#   When in PV9, only the CC members need to approve the cost model, but both
#   CCs and SPOs need to approve the HF.
#
#     - Drep votes are disallowed during Conway bootstrapping.
#
#   When at PV10 or later, both CC members and drep need to approve the cost model.
export ACTION_TX_ID=$(
  cardano-cli latest query gov-state --testnet-magic "$TESTNET_MAGIC" \
    | jq -r '.proposals | map(select(.proposalProcedure.govAction.tag == "ParameterChange")) | .[0].actionId.txId'
)

for i in $(seq 1 "$NUM_CC_KEYS"); do
  echo "Submitting the CC$i vote for the cost model..."
    DECISION=yes \
    ROLE=cc \
    VOTE_KEY="$CC_DIR/cc-$i-hot" \
    nix run .#job-submit-vote
  wait-for-mempool
  echo
done

# REQUIRED if starting in PV10 or later
echo "Submitting the drep-0 vote for the parameter update..."
  DECISION=yes \
  ROLE=drep \
  VOTE_KEY="$DREP_DIR/drep-0" \
  nix run .#job-submit-vote
wait-for-mempool

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 1
echo "Synthesize blocks until just before the cost model proposal ratifies, epoch 1"
synth-slots $((85823 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 1 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 1, verify the gov-state shows PlutusV2 available:
cardano-cli latest query gov-state | jq '.futurePParams.contents.costModels | keys'

# Example output:
# [
#   "PlutusV1",
#   "PlutusV2",
#   "PlutusV3"
# ]

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
echo "Synthesize blocks until realtime plus desired offset"
# This brings us to epoch 1 + 1 = 2
synth-slots $((86363 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 2 days - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 2, verify the gov-state is what is desired, example:
icdiff \
  <(jq -S < scripts/cost-models/vanrossem-parameters-pv11-prep.json) \
  <(cardano-cli query protocol-parameters | jq .costModels)

# Fill the faucet and centrifuge while still in van Rossem as once in Dijkstra
# Tx construction and submission tools are not yet available, and if Leios
# activates, db-synthesizer will cease to function.
#
# Faucet:
#
FAUCET_MNEMONIC=$(just sops-decrypt-binary secrets/envs/"$ENV"/utxo-keys/faucet.mnemonic)
FAUCET_ADDR=$(just sops-decrypt-binary secrets/envs/"$ENV"/utxo-keys/faucet.addr)
UTXO_NUM="5000"
jq -nc --arg addr "$FAUCET_ADDR" --argjson n "$UTXO_NUM" \
  '[range($n) | { ($addr): 10000200000 }]'  | jq '.' > rewards.json

NOMENU=true scripts/distribute.py \
  --testnet-magic "$TESTNET_MAGIC" \
  --signing-key-file "$PAYMENT_KEY.skey" \
  --address "$(cat "$PAYMENT_KEY.addr")" \
  --payments-json rewards.json

cardano-cli debug transaction view --tx-file tx-payments-0-99.txsigned

# shellcheck disable=SC2045
for i in $(ls -tr1 tx-payments*.txsigned); do
  echo "Submitting: $i"
  cardano-cli latest transaction submit --tx-file "$i"
  echo
done

rm ./*.txsigned

UTXO_NUM="100"
jq -nc --arg addr "$FAUCET_ADDR" --argjson n "$UTXO_NUM" \
  '[range($n) | { ($addr): 10000000 }]'  | jq '.' > delegation.json

NOMENU=true scripts/distribute.py \
  --testnet-magic "$TESTNET_MAGIC" \
  --signing-key-file "$PAYMENT_KEY.skey" \
  --address "$(cat "$PAYMENT_KEY.addr")" \
  --payments-json delegation.json

cardano-cli debug transaction view --tx-file tx-payments-0-99.txsigned

# shellcheck disable=SC2045
for i in $(ls -tr1 tx-payments*.txsigned); do
  echo "Submitting: $i"
  cardano-cli latest transaction submit --tx-file "$i"
  echo
done

rm ./*.txsigned

NOMENU=true scripts/setup-delegation-accounts.py \
  --testnet-magic "$TESTNET_MAGIC" \
  --signing-key-file "$PAYMENT_KEY.skey" \
  --wallet-mnemonic <(echo "$FAUCET_MNEMONIC") \
  --num-accounts 100

rm ./*.txsigned

# Centrifuge
#
CENTRIFUGE_ADDR=$(just sops-decrypt-binary secrets/groups/leios1/deploy/leios1-centrifuge-a-1-fund.addr)
ln -sf "$(realpath workbench/custom/rundir/node.socket)" /tmp/cardano-node.sock
export CARDANO_NODE_SOCKET_PATH="/tmp/cardano-node.sock"
NOMENU=true scripts/playground/fund-centrifuge.nu send-funds \
  --funding-address-secret "$PAYMENT_KEY.addr" \
  --funding-signing-key-secret "$PAYMENT_KEY.skey" \
  --destination-address-secret <(echo "$CENTRIFUGE_ADDR") \
  --testnet-magic "$TESTNET_MAGIC" \
  --utxo-count 50000 \
  --utxo-lovelace 10000000000

# In epoch 2, submit a Dijkstra hard fork
echo "Submitting a Dijkstra hard fork action..."
PROPOSAL_ARGS=("--protocol-major-version" "12" "--protocol-minor-version" "0")
ACTION="create-hardfork" \
  STAKE_KEY="$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-stake" \
  nix run .#job-submit-gov-action -- "${PROPOSAL_ARGS[@]}"
wait-for-mempool

export ACTION_TX_ID=$(
  cardano-cli latest query gov-state --testnet-magic "$TESTNET_MAGIC" \
    | jq -r '.proposals | map(select(.proposalProcedure.govAction.tag == "HardForkInitiation")) | .[0].actionId.txId'
)

for i in $(seq 1 "$NUM_CC_KEYS"); do
  echo "Submitting the CC$i vote for the Dijkstra hard fork..."
  DECISION=yes \
    ROLE=cc \
    VOTE_KEY="$CC_DIR/cc-$i-hot" \
    nix run .#job-submit-vote
  wait-for-mempool
  echo
done

echo "Submitting the drep-0 vote for the Dijkstra hard fork..."
  DECISION=yes \
  ROLE=drep \
  VOTE_KEY="$DREP_DIR/drep-0" \
  nix run .#job-submit-vote
wait-for-mempool

echo "Submitting the pool 1 vote for the Dijkstra hard fork..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

echo "Submitting the pool 2 vote for the Dijkstra hard fork..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

echo "Submitting the pool 3 vote for the Dijkstra hard fork..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 2
echo "Synthesize blocks until just before the Dijkstra hard fork ratifies, epoch 3"
synth-slots $((84803 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 3 days - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epcoh 3, verify the Dijkstra hard fork has ratified:
cardano-cli latest query gov-state | jq '.futurePParams.contents.protocolVersion'

# Example output:
# {
#   "major": 12,
#   "minor": 0
# }

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 3
echo "Synthesize blocks until just before the Dijkstra hard fork enacts, epoch 4"
synth-slots $((86339 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 4 days - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 4, verify the Dijkstra hard fork has enacted:
cardano-cli query protocol-parameters | jq .protocolVersion

# Example output:
# {
#   "major": 12,
#   "minor": 0
# }

# Note the current point of the chain; take a backup if desired.
# ❯ cardano-cli query tip
# {
#     "block": 17202,
#     "epoch": 4,
#     "era": "Dijkstra",
#     "hash": "d2f4899ad317b2a1a68e1e276fbad65d2f4fd9f57d94378b78418ad535f2e254",
#     "slot": 345726,
#     "slotInEpoch": 126,
#     "slotsToEpochEnd": 86274,
#     "syncProgress": "93.34"
# }

# Continuing playing the chain at an accelerated rate (100x in this example)
# until the chain is a bit ahead of realtime to allow for seamless transfer.
#
# The datetime provided in the command is the timepoint your want to start
# accelerated forging.
faketime-fast-at "2026-06-01T23:55:00Z" "100"
