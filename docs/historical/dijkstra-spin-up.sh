#!/bin/env bash
# shellcheck disable=SC2031,SC2317,SC2155

# This script is meant more as a guide than an actual straight executable.
# It requires interactivity with node starts, stops, block synthesis and time feedback.

# Source bash helper functions
source scripts/bash-fns.sh

# Basic cardano environment setup vars:
export DEBUG="true"
export ENV="dijkstra"
export UNSTABLE="false"
export UNSTABLE_LIB="false"
export CARDANO_NODE_NETWORK_ID="6"
export TESTNET_MAGIC="6"
export USE_NODE_CONFIG_BP="false"
export NUM_GENESIS_KEYS="3"
export NUM_CC_KEYS="3"
export SECURITY_PARAM="432"
export SLOT_LENGTH="1000"
export START_TIME="2026-10-18T00:00:00Z"
export IPFS_GATEWAY_URI="https://gateway.pinata.cloud"
export USE_GUARDRAILS="true"
export ERA_CMD=conway
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
export POOL_PLEDGE="3000000000000"

# Basic secrets setup vars:
export BULK_CREDS="$GENESIS_DIR/bulk.creds.all.json"
export CC_DIR="$KEY_DIR/cc-keys"
export DREP_DIR="$KEY_DIR/drep"
export PAYMENT_KEY="$KEY_DIR/utxo-keys/rich-utxo"
export USE_ENCRYPTION="false"
export USE_DECRYPTION="false"

# Modified vars from default values specific to the new network:
export           DREP_DEPOSIT="500000000"
export  GOV_ACTION_DEPOSIT="100000000000"
export       VOTING_POWER="1000000000000"
export  FAUCET_DELEGATION="1000000000000"

# Conway constitution specifics for genesis file embedding
# Use a final constitution copy from mainnet to indicate when we are no longer using an interim constitution.
export SCRIPT_FILE_URL="https://book.play.dev.cardano.org/environments-pre/leios/guardrails-script.plutus"
export CONSTITUTION_ANCHOR_DATAHASH="2a61e2f4b63442978140c77a70daab3961b22b12b63b13949a390c097214d1c5"
export CONSTITUTION_ANCHOR_URL="ipfs://bafkreiazhhawe7sjwuthcfgl3mmv2swec7sukvclu3oli7qdyz4uhhuvmy"
export CONSTITUTION_SCRIPT="e3172285605e502bde008a7efe2b2eec516958b7bae911947a5c9373"

# Leios is now rebased on 11.1.0 so take the latest testnet-template.
export TEMPLATE_DIR="$(nix eval --refresh --raw --impure --expr "(builtins.getFlake \"github:input-output-hk/iohk-nix/dijkstra-2026-10\").outPath")/cardano-lib/testnet-template"

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

# Adjust shelley genesis to set minPoolCost and maxBlockBodySize to current
# network standards.
jq -S \
  --argjson major "$PROTOCOL_VERSION_MAJOR" \
  --argjson minor "$PROTOCOL_VERSION_MINOR" \
  '.protocolParams += {
  "minPoolCost": 170000000,
  "maxBlockBodySize": 90112,
  "protocolVersion": {"minor": $minor, "major": $major}
}' < "$DATA_DIR/shelley-genesis.json" | sponge "$DATA_DIR/shelley-genesis.json"


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

# Update genesis hashes in node config after modifying the genesis files.
HASH_CONWAY=$(cardano-cli latest genesis hash --genesis "$DATA_DIR/conway-genesis.json")
HASH_SHELLEY=$(cardano-cli latest genesis hash --genesis "$DATA_DIR/shelley-genesis.json")
HASH_ALONZO=$(cardano-cli latest genesis hash --genesis "$DATA_DIR/alonzo-genesis.json")
jq --sort-keys \
  --arg hashConway "$HASH_CONWAY" \
  --arg hashShelley "$HASH_SHELLEY" \
  --arg hashAlonzo "$HASH_ALONZO" \
  --argjson snapInterval "$SECURITY_PARAM" \
  '. += {
    ConwayGenesisHash: $hashConway,
    ShelleyGenesisHash: $hashShelley,
    AlonzoGenesisHash: $hashAlonzo,
  } | .LedgerDB.Snapshots.SnapshotInterval = ($snapInterval * 40)
  ' \
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

# If both cost model and hard fork proposal are submitted in the same epoch, the
# cost model will fail to take effect. We'll delay submission of any HF proposal
# by one epoch to allow for ratification of the cost model first.
echo "Submitting a cost model governance action..."
PROPOSAL_ARGS=("--cost-model-file" "scripts/cost-models/vanrossem-parameters-pv11-prep.json")
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
# due to broken db-synthesizer 4.2.1.0 (node 11.1.3) we use 5.1.0.2 (node 11.2.0)
UNSTABLE=true synth-slots $((85567 - 60))
# do not run back-to-back
run-node-faketime "$(date -u -d "$START_TIME + 1 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 1, verify the gov-state shows PlutusV2 available:
cardano-cli latest query gov-state | jq '.futurePParams.contents.costModels | keys'

# Expected output:
# [
#   "PlutusV1",
#   "PlutusV2",
#   "PlutusV3"
# ]

# Let a few blocks forge and then obtain slotsToEpochEnd from `cardano-cli latest query tip`
echo "Synthesize blocks until realtime plus desired offset"
# This brings us to epoch 1 + 1 = 2
UNSTABLE=true synth-slots $((86084 - 60))
# do not run back-to-back
# run 2 epochs after the start
run-node-faketime "$(date -u -d "$START_TIME + 2 day - 1 minute" "+%Y-%m-%dT%H:%M:%SZ")"

# After the epoch rollover into epoch 2, verify the gov-state is what is desired, example:
icdiff \
  <(jq -S < scripts/cost-models/vanrossem-parameters-pv11-prep.json) \
  <(cardano-cli query protocol-parameters | jq .costModels)

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

cardano-cli debug transaction view --tx-file tx-payments-0-99.txsigned | less

# shellcheck disable=SC2045
for i in $(ls -tr1 tx-payments*.txsigned); do
  echo "Submitting: $i"
  cardano-cli latest transaction submit --tx-file "$i"
  echo
done

watch 'cardano-cli query tip; echo; cardano-cli query tx-mempool info'
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

cardano-cli debug transaction view --tx-file tx-payments-0-99.txsigned | less

# shellcheck disable=SC2045
for i in $(ls -tr1 tx-payments*.txsigned); do
  echo "Submitting: $i"
  cardano-cli latest transaction submit --tx-file "$i"
  echo
done

watch 'cardano-cli query tip; echo; cardano-cli query tx-mempool info'
cardano-cli query utxo --address "$FAUCET_ADDR" | jq length
rm ./*.txsigned

# Setup the faucet stakepool delegation
NOMENU=true scripts/setup-delegation-accounts.py \
  --testnet-magic "$TESTNET_MAGIC" \
  --signing-key-file "$PAYMENT_KEY.skey" \
  --wallet-mnemonic <(echo "$FAUCET_MNEMONIC") \
  --num-accounts "500" \
  --delegation-amount "$FAUCET_DELEGATION"

cardano-cli query utxo --whole-utxo \
  | jq --argjson faucetDeleg "$FAUCET_DELEGATION" \
    'to_entries | map(select(.value.value.lovelace == $faucetDeleg)) | length'
rm ./*.txsigned

# deploy until
# Wed, 21 Oct 2026 13:43:50 +0200 (in an hour)
# we forward this to future realtime in hopes that the deploy happens before this.
run-node-faketime 2026-10-21T14:40:00+00:00

