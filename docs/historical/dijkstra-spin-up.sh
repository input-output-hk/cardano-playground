#!/bin/env bash
# shellcheck disable=SC2031,SC2317,SC2155

# This script is meant more as a guide than an actual straight executable.
# It requires interactivity with node starts, stops, block synthesis and time feedback.

# Source bash helper functions
source scripts/bash-fns.sh

# Basic cardano environment setup vars:
export DEBUG="true"
export ENV="dijkstra"
export UNSTABLE="true"
export UNSTABLE_LIB="true"
export CARDANO_NODE_NETWORK_ID="6"
export TESTNET_MAGIC="6"
export USE_NODE_CONFIG_BP="false"
export NUM_GENESIS_KEYS="3"
export NUM_CC_KEYS="3"
export SECURITY_PARAM="432"
export SLOT_LENGTH="1000"
export START_TIME="2026-02-15T00:00:00Z"
export IPFS_GATEWAY_URI="https://ipfs.io"
export USE_GUARDRAILS="true"
export ERA_CMD=conway

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

# Create the basic cardano network config and secrets
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

# Update the conway hash in node config after modifying the genesis file.
HASH_CONWAY=$(cardano-cli-ng latest genesis hash --genesis "$DATA_DIR/conway-genesis.json")
jq --sort-keys \
  --arg hashConway "$HASH_CONWAY" \
  '. += {
    ConwayGenesisHash: $hashConway,
  }' \
  < "$DATA_DIR/node-config.json" \
  | sponge "$DATA_DIR/node-config.json"

# At this point interactivity will be required.
# This script will exit and the remainder can be executed interactivity using
# the following as a guide.
exit 0

# Start the node 30 seconds before the chain is scheduled to start forging.
# Note that if you run older versions of node, the libfaketime will need to
# match the glibc version.  In this case, the run-node-faketime fn can be
# modified to use an older libfaketime package with the appropriate glibc build
# using somthing like:
#   nix run github:nixos/nixpkgs/nixos-23.05#libfaketime -- "$1" "$CMD" run ...
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

# If both cost model and Plomin hard fork proposal are submitted in the same
# epoch, the cost model will fail to take effect and PlutusV2 will be
# missing.  We'll delay submission of Plutus HF proposal by one epoch to
# allow for ratification of the cost model first.
echo "Submitting a Plomin prep cost model action..."
PROPOSAL_ARGS=("--cost-model-file" "scripts/cost-models/mainnet-plutusv3-pv10-prep.json")
ACTION="create-protocol-parameters-update" \
  STAKE_KEY="$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-stake" \
  nix run .#job-submit-gov-action -- "${PROPOSAL_ARGS[@]}"
wait-for-mempool

# Only the CC members need to approve the cost model, but both CCs and SPOs need to approve the HF.
# Drep votes are disallowed during Conway bootstrapping.
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

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 1
echo "Synthesize blocks until just before the cost model proposal ratifies, epoch 1"
synth-slots $((86400 - 595 - 180))
run-node-faketime "$(date -u -d "$START_TIME + 1 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 1, verify the gov-state shows PlutusV2 available:
cardano-cli latest query gov-state | jq '.futurePParams.contents.costModels | keys'

# Example output:
# [
#   "PlutusV1",
#   "PlutusV2",
#   "PlutusV3"
# ]

# In epoch 1, submit a Plomin hard fork
echo "Submitting a Plomin hard fork action..."
PROPOSAL_ARGS=("--protocol-major-version" "10" "--protocol-minor-version" "0")
ACTION="create-hardfork" \
  STAKE_KEY="$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-stake" \
  nix run .#job-submit-gov-action -- "${PROPOSAL_ARGS[@]}"
wait-for-mempool

export ACTION_TX_ID=$(
  cardano-cli latest query gov-state --testnet-magic "$TESTNET_MAGIC" \
    | jq -r '.proposals | map(select(.proposalProcedure.govAction.tag == "HardForkInitiation")) | .[0].actionId.txId'
)

for i in $(seq 1 "$NUM_CC_KEYS"); do
  echo "Submitting the CC$i vote for the Plomin hard fork..."
  DECISION=yes \
    ROLE=cc \
    VOTE_KEY="$CC_DIR/cc-$i-hot" \
    nix run .#job-submit-vote
  wait-for-mempool
  echo
done

echo "Submitting the pool 1 vote for the Plomin hard fork..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

echo "Submitting the pool 2 vote for the Plomin hard fork..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

echo "Submitting the pool 3 vote for the Plomin hard fork..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 2
echo "Synthesize blocks until just before the Plomin hard fork ratifies, epoch 2"
synth-slots $((86053 - 180))
run-node-faketime "$(date -u -d "$START_TIME + 2 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epcoh 2, verify the Plomin hard fork has ratified:
cardano-cli latest query gov-state | jq '.futurePParams.contents.protocolVersion'

# Example output:
# {
#   "major": 10,
#   "minor": 0
# }

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 3
echo "Synthesize blocks until just before the Plomin hard fork enacts, epoch 3"
synth-slots $((86300 - 180))
run-node-faketime "$(date -u -d "$START_TIME + 3 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epcoh 3, verify the Plomin hard fork has enacted:
cardano-cli query protocol-parameters | jq .protocolVersion

# Example output:
# {
#   "major": 10,
#   "minor": 0
# }

# Submit a parameter change action to adjust network parameters to better match other networks
echo "Submitting a ParameterChange action..."
PREV_GOV_ACTION=$(cardano-cli latest query gov-state --testnet-magic "$TESTNET_MAGIC" | jq -r '.nextRatifyState.nextEnactState.prevGovActionIds.PParamUpdate')
PREV_GOV_ACTION_TX_ID=$(jq '.txId' <<< "$PREV_GOV_ACTION")
PREV_GOV_ACTION_INDEX=$(jq '.govActionIx' <<< "$PREV_GOV_ACTION")
PROPOSAL_ARGS=(
  "--prev-governance-action-tx-id" "$PREV_GOV_ACTION_TX_ID"
  "--prev-governance-action-index" "$PREV_GOV_ACTION_INDEX"
  "--max-block-body-size" "90112"
  # The steps are expected to be declared first, followed by the memory in the tuple ordering
  "--max-block-execution-units" "\(20000000000,72000000\)"
  "--max-tx-execution-units" "\(10000000000,16500000\)"
  "--min-pool-cost" "170000000"
)
ACTION="create-protocol-parameters-update" \
  STAKE_KEY="$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-stake" \
  nix run .#job-submit-gov-action -- "${PROPOSAL_ARGS[@]}"
wait-for-mempool

export ACTION_TX_ID=$(
  cardano-cli latest query gov-state --testnet-magic "$TESTNET_MAGIC" \
    | jq -r '.proposals | map(select(.proposalProcedure.govAction.tag == "ParameterChange")) | .[0].actionId.txId'
)

for i in $(seq 1 "$NUM_CC_KEYS"); do
  echo "Submitting the CC$i vote for the parameter update..."
  DECISION=yes \
    ROLE=cc \
    VOTE_KEY="$CC_DIR/cc-$i-hot" \
    nix run .#job-submit-vote
  wait-for-mempool
  echo
done

echo "Submitting the pool 1 vote for the parameter update..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

echo "Submitting the pool 2 vote for the parameter update..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

echo "Submitting the pool 3 vote for the parameter update..."
DECISION=yes \
  ROLE=spo \
  VOTE_KEY="$GENESIS_DIR/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-cold" \
  nix run .#job-submit-vote
wait-for-mempool

echo "Submitting the drep-0 vote for the parameter update..."
  DECISION=yes \
  ROLE=drep \
  VOTE_KEY="$DREP_DIR/drep-0" \
  nix run .#job-submit-vote
wait-for-mempool

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 4
echo "Synthesize blocks until just before the parameter change ratifies, epoch 4"
synth-slots $((85987 - 180))
run-node-faketime "$(date -u -d "$START_TIME + 4 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# Ensure the parameter change has ratified once epoch 4 is reached:
cardano-cli latest query gov-state \
  | jq '.futurePParams.contents | {maxBlockBodySize,maxBlockExecutionUnits,maxTxExecutionUnits,minPoolCost}'

# Example
# {
#   "maxBlockBodySize": 90112,
#   "maxBlockExecutionUnits": {
#     "memory": 72000000,
#     "steps": 20000000000
#   },
#   "maxTxExecutionUnits": {
#     "memory": 16500000,
#     "steps": 10000000000
#   },
#   "minPoolCost": 170000000
# }

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 5
echo "Synthesize blocks until just before the parameter change enacts, epoch 5"
synth-slots $((86298 - 180))
run-node-faketime "$(date -u -d "$START_TIME + 5 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# Ensure the parameter change has enacted once epoch 5 is reached:
cardano-cli latest query protocol-parameters \
  | jq '{maxBlockBodySize,maxBlockExecutionUnits,maxTxExecutionUnits,minPoolCost}'

# Example
# {
#   "maxBlockBodySize": 90112,
#   "maxBlockExecutionUnits": {
#     "memory": 72000000,
#     "steps": 20000000000
#   },
#   "maxTxExecutionUnits": {
#     "memory": 16500000,
#     "steps": 10000000000
#   },
#   "minPoolCost": 170000000
# }

# Synth to real time
# First get to next epoch threshold (no 3 minute substraction back from the epoch boundary):
synth-slots 86293

# Then synth the number of epochs to get the current day, UTC
synth-epochs 13

# Finally, synth to slightly ahead of real time, using the number of hours in
# the current day UTC to prepare for a push to the remote machines -- 3 hours in
# this example.
synth-slots $((3 * 3600))

# Start the node for a moment at it's current near-future (shortly after now)
# tip time in order to allow node to process all the volatile state into
# immutable and ledger as required.  Once that is complete, node can be stopped
# and the state can be tgz packaged or similar in prep for a push to the remote
# backbone machines.
run-node-faketime '2026-01-20 03:00:00Z'

# See docs/explain/new-network.md for details on migrating this prepared chain
# state from a local preparation environment to the full remote machine cluster.
