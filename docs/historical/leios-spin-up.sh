#!/bin/env bash
# shellcheck disable=SC2031,SC2317,SC2155,SC2139

# This script is meant more as a guide than an actual straight executable.
# It requires interactivity with node starts, stops, block synthesis and time feedback.

# Source bash helper functions
source scripts/bash-fns.sh

# Basic cardano environment setup vars:
export USE_SHELL_BINS="true"
alias cardano-node="$(nix build -Lv github:IntersectMBO/cardano-node/leios-prototype#cardano-node --no-link --print-out-paths)/bin/cardano-node"
alias cardano-node-ng="$(nix build -Lv github:IntersectMBO/cardano-node/leios-prototype#cardano-node --no-link --print-out-paths)/bin/cardano-node"
alias cardano-cli="$(nix build -Lv github:IntersectMBO/cardano-node/leios-prototype#cardano-cli --no-link --print-out-paths)/bin/cardano-cli"
alias cardano-cli-ng="$(nix build -Lv github:IntersectMBO/cardano-node/leios-prototype#cardano-cli --no-link --print-out-paths)/bin/cardano-cli"
alias db-synthesizer="$(nix build -Lv github:IntersectMBO/cardano-node/leios-prototype#db-synthesizer --no-link --print-out-paths)/bin/db-synthesizer"
alias db-synthesizer-ng="$(nix build -Lv github:IntersectMBO/cardano-node/leios-prototype#db-synthesizer --no-link --print-out-paths)/bin/db-synthesizer"

# Expect leios currently at ~10.5.1
cardano-node --version
cardano-node-ng --version

# Expect leios currently at ~10.11.0.0
cardano-cli --version
cardano-cli-ng --version

export DEBUG="true"

export ENV="leios"
export UNSTABLE="false"
export UNSTABLE_LIB="false"
export CARDANO_NODE_NETWORK_ID="7"
export TESTNET_MAGIC="7"
export USE_NODE_CONFIG_BP="false"
export NUM_GENESIS_KEYS="3"
export NUM_CC_KEYS="3"
export SECURITY_PARAM="432"
export SLOT_LENGTH="1000"
export START_TIME="2026-04-17T00:00:00Z"
export IPFS_GATEWAY_URI="https://ipfs.io"
export USE_GUARDRAILS="true"
export ERA_CMD=conway
export PROTOCOL_VERSION_MAJOR="10"
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
# Required to match the proper GLIBC used by the 10.5.1 era build
export FAKETIME_FLAKE="github:nixos/nixpkgs/nixos-23.05"
export LEIOS_DB_PATH="$DATA_DIR/leios.db"

# Leios is currently based on a dated 10.5.1 node branch, but will eventually
# be rebased on master. Lets take the approach of using the latest config
# template and node binary to generate genesis config, and then patch for
# backwards compatible changes that are needed until the leios rebase to master
# happens.
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

# Adjust shelley genesis to set minPoolCost and maxBlockBodySize closer to mainnet
jq -S '.protocolParams += {
  "minPoolCost": 170000000,
  "maxBlockBodySize": 90112
}' < "$DATA_DIR/shelley-genesis.json" | sponge "$DATA_DIR/shelley-genesis.json"

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

# NOTE:
# Injecting the current mainnet PV10 cost model into alonzo does not seem to
# get picked up it by it, so comment this genesis file replacement out and
# continue to submit the cost model update via gov action.
#
# Replace alonzo genesis costModels with the Plomin prep cost model
# jq -S --slurpfile costModels scripts/cost-models/mainnet-plutusv3-pv10-prep.json \
#   '.costModels = $costModels[0]' \
#   < "$DATA_DIR/alonzo-genesis.json" \
#   | sponge "$DATA_DIR/alonzo-genesis.json"

# NOTE: This old stakepool format in genesis should be forward compatible
# Leios oriented 10.5.x stake pool genesis format reconfiguration:
jq '.staking.pools
  |= with_entries(.value += {publicKey: .key}
  | .value.rewardAccount = .value.accountAddress
  | del(.value.accountAddress, .value.poolId))' \
"$DATA_DIR/shelley-genesis.json" | sponge "$DATA_DIR/shelley-genesis.json"

# Shim the 10.7.x node config to be compatible back to 10.5.x until leios rebases to master.
# This will require:
#   - Add relay role config of the following which has been handled dynamically since 10.6.0:
#     - PeerSharing = true (should be false for a bp)
#     - TargetNumberOfKnownPeers = 150  (should be 100 for a bp)
#     - TargetNumberOfRootPeers = 60 (should be 100 for a bp)
#     - EnableP2P (removed legacy networking in 10.6.0)
jq -S '.EnableP2P = true
  | .PeerSharing = true
  | .TargetNumberOfKnownPeers = 150
  | .TargetNumberOfRootPeers = 60
  | .LedgerDB.SnapshotInterval = 864
  | .MempoolCapacityBytesOverride = 25000000' \
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

# NOTE:
#   When in PV9, only the CC members need to approve the cost model, but both
#   CCs and SPOs need to approve the HF.
#
#     - Drep votes are disallowed during Conway bootstrapping.
#
#   When in PV10, both CC members and drep need to approve the cost model.
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

# REQUIRED if starting in PV10
echo "Submitting the drep-0 vote for the parameter update..."
  DECISION=yes \
  ROLE=drep \
  VOTE_KEY="$DREP_DIR/drep-0" \
  nix run .#job-submit-vote
wait-for-mempool

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 1
echo "Synthesize blocks until just before the cost model proposal ratifies, epoch 1"
synth-slots $((86400 - 623 - 180))
run-node-faketime "$(date -u -d "$START_TIME + 1 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 1, verify the gov-state shows PlutusV2 available:
cardano-cli latest query gov-state | jq '.futurePParams.contents.costModels | keys'

# Example output:
# [
#   "PlutusV1",
#   "PlutusV2",
#   "PlutusV3"
# ]

# NOTE:
#   If starting in PV10, there is no need to submit the PV10 hard fork.
#   See the historical dijkstra doc in playground for a PV10 HF example.

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
echo "Synthesize blocks until realtime plus desired offset"
# This brings us to epoch 1 + 1 = 2
synth-slots 86299
#
# This brings us to epoch 2 + 4 = 6
synth-epochs 4

run-node-faketime "$(date -u -d "$START_TIME + 6 day - 30 minute" "+%Y-%m-%dT%H:%M:%SZ")"
