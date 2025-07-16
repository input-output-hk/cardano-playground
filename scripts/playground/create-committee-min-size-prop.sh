#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

[ -z "${ANCHOR_URL:-}" ] && { echo "ANCHOR_URL var must be set and should point to an ipfs://\$CIDv1 address"; exit 1; }
[ -z "${DREP_INDEX:-}" ] && { echo "DREP_INDEX var must be set"; exit 1; }
[ -z "${TESTNET_MAGIC:-}" ] && { echo "TESTNET_MAGIC var must be set"; exit 1; }
[ -z "${COMMITTEE_MIN_SIZE:-}" ] && { echo "COMMITTEE_MIN_SIZE var must be set"; exit 1; }

export IPFS_GATEWAY_URI="https://ipfs.io"

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")


# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

PP=$(cardano-cli query protocol-parameters)
ANCHOR_HASH=$(cardano-cli hash anchor-data --url "$ANCHOR_URL")
CURRENT_EPOCH=$(cardano-cli query tip | jq .epoch)
CURRENT_COMMITTEE_MIN_SIZE=$(cardano-cli query protocol-parameters | jq .committeeMinSize)
PREV_GOV_ACTION=$(cardano-cli latest query gov-state | jq -r '.nextRatifyState.nextEnactState.prevGovActionIds.PParamUpdate')
PREV_GOV_ACTION_TX_ID=$(jq '.txId' <<< "$PREV_GOV_ACTION")
PREV_GOV_ACTION_INDEX=$(jq '.govActionIx' <<< "$PREV_GOV_ACTION")
DREP_DEPOSIT=$(jq -r '.dRepDeposit' <<< "$PP")
GOV_ACTION_DEPOSIT=$(jq -r '.govActionDeposit' <<< "$PP")
GUARDRAILS_SCRIPT_HASH=$(cardano-cli hash script --script-file <(curl -sL "https://book.play.dev.cardano.org/environments/$ENV/guardrails-script.plutus"))
echo "Current epoch on $ENV is: $CURRENT_EPOCH"
echo "Current committee min size on $ENV is: $CURRENT_COMMITTEE_MIN_SIZE"
echo "Desired committee min size on $ENV is: $COMMITTEE_MIN_SIZE"
echo "Drep deposit is: $DREP_DEPOSIT"
echo "Governance action deposit is: $GOV_ACTION_DEPOSIT"
echo
echo "If you see a plutus script failure, check that your proposed change is allowed by the guardrails script:"
echo
echo "  https://github.com/IntersectMBO/plutus/blob/master/cardano-constitution/data/defaultConstitution.json"

# Create a governance update action and submit it.
PROPOSAL_ARGS=(
  "--min-committee-size" "$COMMITTEE_MIN_SIZE"
  "--prev-governance-action-tx-id" "$PREV_GOV_ACTION_TX_ID"
  "--prev-governance-action-index" "$PREV_GOV_ACTION_INDEX"
  "--constitution-script-hash" "$GUARDRAILS_SCRIPT_HASH"
)

ACTION="create-protocol-parameters-update" \
  DREP_DIR="$SCRIPT_DIR/../../secrets/envs/$ENV/drep" \
  GOV_ACTION_DEPOSIT="$GOV_ACTION_DEPOSIT" \
  PAYMENT_KEY="$SCRIPT_DIR/../../secrets/envs/$ENV/utxo-keys/rich-utxo" \
  PROPOSAL_HASH="$ANCHOR_HASH" \
  PROPOSAL_URL="$ANCHOR_URL" \
  STAKE_KEY="$SCRIPT_DIR/../../secrets/envs/$ENV/drep/stake-$DREP_INDEX" \
  SUBMIT_TX="false" \
  USE_DECRYPTION="true" \
  USE_GUARDRAILS="true" \
  USE_ENCRYPTION="false" \
  nix run .#job-submit-gov-action -- "${PROPOSAL_ARGS[@]}"
