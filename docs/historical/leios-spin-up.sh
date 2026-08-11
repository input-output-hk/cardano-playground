#!/usr/bin/env bash
# shellcheck disable=SC2031,SC2317,SC2155,SC2139

# This script is meant more as a guide than an actual straight executable.
# It requires interactivity with node starts, stops, block synthesis and time feedback.

# Updated for leios-prototype-2026w32

# Source bash helper functions
# TODO: Unify the dual approach of alias and default shell bins between bash-fns.sh and nix jobs
source scripts/bash-fns.sh

# Basic cardano environment setup vars and bins:
export USE_SHELL_BINS="true"
LEIOS_PIN=$(jq -r '.nodes[.nodes."cardano-node-leios".inputs."cardano-node-leios"].locked | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock)

# Aliases required for bash-fns.sh
alias cardano-node="$(nix build -Lv "$LEIOS_PIN#cardano-node" --no-link --print-out-paths)/bin/cardano-node"
alias cardano-cli="$(nix build -Lv "$LEIOS_PIN#cardano-cli" --no-link --print-out-paths)/bin/cardano-cli"
alias db-analyser="$(nix build -Lv "$LEIOS_PIN#db-analyser" --no-link --print-out-paths)/bin/db-analyser"
alias db-immutaliser="$(nix build -Lv "$LEIOS_PIN#project.x86_64-linux.hsPkgs.ouroboros-consensus.components.exes.db-immutaliser" --no-link --print-out-paths)/bin/db-immutaliser"
alias db-synthesizer="$(nix build -Lv "$LEIOS_PIN#db-synthesizer" --no-link --print-out-paths)/bin/db-synthesizer"
alias db-truncater="$(nix build -Lv "$LEIOS_PIN#db-truncater" --no-link --print-out-paths)/bin/db-truncater"

# Alias the pre-release bins as well to ensure consistent bin usage
alias cardano-node-ng=cardano-node
alias cardano-cli-ng=cardano-cli
alias db-analyser-ng=db-analyser
alias db-analyser-ng=db-immutaliser
alias db-synthesizer-ng=db-synthesizer
alias db-truncater-ng=db-truncater

# Export the leios bins to subshells where aliases don't work
source scripts/playground/leios-pin.sh

# Expect leios currently at 11.1.0.164
cardano-node --version
cardano-node-ng --version

# Expect leios currently at 11.1.0.0
cardano-cli --version
cardano-cli-ng --version

export DEBUG="true"
export ENV="leios"
export UNSTABLE="true"
export UNSTABLE_LIB="true"
export CARDANO_NODE_NETWORK_ID="164"
export TESTNET_MAGIC="164"
export USE_NODE_CONFIG_BP="false"
export NUM_GENESIS_KEYS="3"
export NUM_CC_KEYS="3"
# Security param:
#   432 for 1 day epoch
#   216 for 12 hr epoch
#   108 for 6 hr epoch
#    54 for 3 hr epoch
#    32 for 2 hr epoch
#
# Security implications:
#   Calculated as (k/f) / 50% until ForkTooDeep (FTD) and 3k/f no-forge tolerance:
#     1 day epoch: ~4.8 hrs at 50% partition until FTD, 7.2 hrs no-forge tolerance
#     12 hr epoch: ~2.4 hrs at 50% partition until FTD, 3.6 hrs no-forge tolerance
#     6 hr epoch:  ~1.2 hrs at 50% partition until FTD, 1.8 hrs no-forge tolerance
export SECURITY_PARAM="108"
export SLOT_LENGTH="1000"

# At 6 hr epochs, there are 4 epochs per day:
#   4 are required for standard spin up procedure below to get to Dijkstra
#   ~4 are required for Dijkstra era pool re-registration for BLS keys
#   <= 4 are required for rounding to the next full day at 00:00 UTC
#
#   Total: 8 <= x <= 12 epochs
export START_TIME="2026-08-07T00:00:00Z"
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
export POOL_METADATA_BASE_URL="https://pools.play.dev.cardano.org"
export POOL_RELAY="$ENV-node.play.dev.cardano.org"
export POOL_RELAY_PORT="3001"
# For now, faucet will be:
#   10000200000 lovelace (10k ADA) funding utxos @ 5000 count,
#   1000000000000 (1M ADA) Faucet delegation,
export FAUCET_DELEGATION="1000000000000"
#   10000000 (10 ADA) delegation UTxO @ 500 count for 500 SPO delegations

# For stability, our pool pledge will be 10M ADA
export POOL_PLEDGE="10000000000000"
export USE_BLS="false"

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
# The new leios remake at 11.1.0 does not require faketime glibc adjustment.
# export FAKETIME_FLAKE="github:nixos/nixpkgs/nixos-23.05"

# Leios is now rebased on 11.1.0 so take the latest testnet-template.
export TEMPLATE_DIR="$(nix eval --raw --impure --expr "let f = builtins.getFlake \"github:input-output-hk/iohk-nix/node-11.1\"; in f.outPath")/cardano-lib/testnet-template"

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
# This will become available once https://github.com/IntersectMBO/cardano-ledger/pull/5899 is merged and in use
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
jq -S --argjson snapInterval "$((40 * SECURITY_PARAM))" \
  '.ExperimentalHardForksEnabled = true
  | .MempoolCapacityBytesOverride = 500000
  | .LedgerDB.Snapshots.SnapshotInterval = $snapInterval
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
synth-slots $((21090 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 6 hours - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

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
synth-slots $((21476 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 12 hours - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

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
UTXO_NUM="10000"
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

cardano-cli query utxo --address "$FAUCET_ADDR" | jq length
rm ./*.txsigned


UTXO_NUM="500"
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

cardano-cli query utxo --address "$FAUCET_ADDR" | jq length
rm ./*.txsigned

# Setup the faucet stakepool delegation
NOMENU=true scripts/setup-delegation-accounts.py \
  --testnet-magic "$TESTNET_MAGIC" \
  --signing-key-file "$PAYMENT_KEY.skey" \
  --wallet-mnemonic <(echo "$FAUCET_MNEMONIC") \
  --num-accounts "500" \
  --delegation-amount "$FAUCET_DELEGATION"

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

cardano-cli query utxo --address "$CENTRIFUGE_ADDR" | jq length

# In epoch 2, submit a Dijkstra hard fork:
# For w32 respin, submitted at block:
# {
#     "block": 2274,
#     "epoch": 2,
#     "era": "Conway",
#     "hash": "396a997437f3a7e421ca3911ec13c5f4a144e7eecd533f33ec8c9b5af45c2d18",
#     "slot": 45188,
#     "slotInEpoch": 1988,
#     "slotsToEpochEnd": 19612,
#     "syncProgress": "12.67"
# }
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
# Start 1m before epoch 3
echo "Synthesize blocks until just before the Dijkstra hard fork ratifies, epoch 3"
synth-slots $((19301 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 18 hours - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 3, verify the Dijkstra hard fork has ratified:
cardano-cli latest query gov-state | jq '.futurePParams.contents.protocolVersion'

# Example output:
# {
#   "major": 12,
#   "minor": 0
# }

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 4
echo "Synthesize blocks until just before the Dijkstra hard fork enacts, epoch 4"
synth-slots $((21407 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 24 hours - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 4, verify the Dijkstra hard fork has enacted:
cardano-cli query protocol-parameters | jq .protocolVersion

# Example output:
# {
#   "major": 12,
#   "minor": 0
# }

# Reregister the pools with BLS keys
# First back up the pool state and ledger state to compare before making modifications
cardano-cli query pool-state --all-stake-pools > pool-state.json
cardano-cli query ledger-state > ledger-state.json

# Then generate BLS keys for the pools
POOL_NAMES="leios1-bp-a-1" \
  ERA_CMD=dijkstra \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}1" \
  nix run .#job-create-stake-pool-bls-keys

POOL_NAMES="leios2-bp-b-1" \
  ERA_CMD=dijkstra \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}2" \
  nix run .#job-create-stake-pool-bls-keys

POOL_NAMES="leios3-bp-c-1" \
  ERA_CMD=dijkstra \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}3" \
  nix run .#job-create-stake-pool-bls-keys

# And finally, re-register the pools with the BLS keys
POOL_NAMES="leios1-bp-a-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}1" \
  ERA_CMD=dijkstra \
  USE_BLS=true \
  SUBMIT_TX=true \
  nix run .#job-reregister-stake-pools

POOL_NAMES="leios2-bp-b-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}2" \
  ERA_CMD=dijkstra \
  USE_BLS=true \
  SUBMIT_TX=true \
  nix run .#job-reregister-stake-pools

POOL_NAMES="leios3-bp-c-1" \
  STAKE_POOL_DIR="$GENESIS_DIR/groups/${ENV}3" \
  ERA_CMD=dijkstra \
  USE_BLS=true \
  SUBMIT_TX=true \
  nix run .#job-reregister-stake-pools

# Check for futurePoolParams and that it includes a spsLeiosKey struct
cardano-cli query pool-state --all-stake-pools

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 5
echo "Synthesize blocks until just before the Dijkstra hard fork enacts, epoch 5"
synth-slots $((19648 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 30 hours - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# Check that spsLeiosKey has been incorporated into the pools
# This should now be "Mark" stake snapshot with BLS keys present
cardano-cli query pool-state --all-stake-pools

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 6
echo "Synthesize blocks until just before the Dijkstra hard fork enacts, epoch 6"
synth-slots $((21448 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 36 hours - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# This should now be "Set" stake snapshot with BLS keys present
# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
# Start 1m before epoch 7
echo "Synthesize blocks until just before the Dijkstra hard fork enacts, epoch 7"
synth-slots $((21383 - 60))
run-node-faketime "$(date -u -d "$START_TIME + 42 hours - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# This should now be "Go" stake snapshot with BLS keys present
# BLS keys should now be active for Leios (as of "Set" snapshot)

# Note the current point of the chain and log time; take a backup if desired.
# ❯ cardano-cli query tip
# {
#     "block": 7581,
#     "epoch": 7,
#     "era": "Dijkstra",
#     "hash": "4fee052187c142fd08d13fa1b7b548aea49a042554aa2378c56db460773f0320",
#     "slot": 151599,
#     "slotInEpoch": 399,
#     "slotsToEpochEnd": 21201,
#     "syncProgress": "41.64"
# }
#
# 2026-08-08 18:06:52.0022

# Calculate the required slots to reach realtime and project slightly forward,
# where the first time is the target and the second time is the last log stamp
# above:
echo $(( $(date -u -d '2026-08-11 06:00:00Z' +%s) - $(date -u -d '2026-08-08 18:06:52Z' +%s) ))
215588

echo "Synthesize blocks until the just ahead of realtime target"
synth-slots 215588

# Or, alternatively, continue playing the chain at an accelerated rate (100x in this example)
# until the chain is a bit ahead of realtime to allow for seamless transfer.
#
# The datetime provided in the command is the timepoint your want to start
# accelerated forging.
faketime-fast-at "2026-08-08T18:06:52Z" "100"
