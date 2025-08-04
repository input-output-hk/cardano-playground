#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

[ -z "${ANCHOR_URL:-}" ] && { echo "ANCHOR_URL var must be set and should point to an ipfs://\$CIDv1 address"; exit 1; }
[ -z "${DREP_INDEX:-}" ] && { echo "DREP_INDEX var must be set"; exit 1; }
[ -z "${TESTNET_MAGIC:-}" ] && { echo "TESTNET_MAGIC var must be set"; exit 1; }
[ -z "${THRESHOLD:-}" ] && { echo "THRESHOLD var must be set and most likely should remain the same as the existing threshold"; exit 1; }

export IPFS_GATEWAY_URI="https://ipfs.io"

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

PP=$(cardano-cli query protocol-parameters)
ANCHOR_HASH=$(cardano-cli hash anchor-data --url "$ANCHOR_URL")
CURRENT_EPOCH=$(cardano-cli query tip | jq .epoch)
DREP_DEPOSIT=$(jq -r '.dRepDeposit' <<< "$PP")
GOV_ACTION_DEPOSIT=$(jq -r '.govActionDeposit' <<< "$PP")
PREV_GOV_ACTION=$(cardano-cli latest query gov-state | jq -r '.nextRatifyState.nextEnactState.prevGovActionIds.Committee')
PREV_GOV_ACTION_TX_ID=$(jq '.txId' <<< "$PREV_GOV_ACTION")
PREV_GOV_ACTION_INDEX=$(jq '.govActionIx' <<< "$PREV_GOV_ACTION")
echo "Current epoch on $ENV is: $CURRENT_EPOCH"
echo "Drep deposit is: $DREP_DEPOSIT"
echo "Governance action deposit is: $GOV_ACTION_DEPOSIT"

# Create a governance update action and submit it.
PROPOSAL_ARGS=(
  "--prev-governance-action-tx-id" "$PREV_GOV_ACTION_TX_ID"
  "--prev-governance-action-index" "$PREV_GOV_ACTION_INDEX"
  "--check-anchor-data"
  "--threshold" "$THRESHOLD"
  "--remove-cc-cold-verification-key-hash" "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/cc4/init-cold/credential.plutus.hash")"
  "--remove-cc-cold-verification-key-hash" "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/cc5/init-cold/credential.plutus.hash")"
  "--remove-cc-cold-verification-key-hash" "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/cc6/init-cold/credential.plutus.hash")"
  "--remove-cc-cold-verification-key-hash" "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/cc7/init-cold/credential.plutus.hash")"
  "--remove-cc-cold-verification-key-hash" "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/icc-keys/init-cold/credential.plutus.hash")"
)

ACTION="update-committee" \
  DREP_DIR="$SCRIPT_DIR/../../secrets/envs/$ENV/drep" \
  GOV_ACTION_DEPOSIT="$GOV_ACTION_DEPOSIT" \
  PAYMENT_KEY="$SCRIPT_DIR/../../secrets/envs/$ENV/utxo-keys/rich-utxo" \
  PROPOSAL_HASH="$ANCHOR_HASH" \
  PROPOSAL_URL="$ANCHOR_URL" \
  STAKE_KEY="$SCRIPT_DIR/../../secrets/envs/$ENV/drep/stake-$DREP_INDEX" \
  SUBMIT_TX="false" \
  USE_DECRYPTION="true" \
  USE_ENCRYPTION="false" \
  nix run .#job-submit-gov-action -- "${PROPOSAL_ARGS[@]}"
