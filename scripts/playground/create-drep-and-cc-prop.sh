#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

[ -z "${ANCHOR_URL:-}" ] && { echo "ANCHOR_URL var must be set and should point to an ipfs://\$CIDv1 address"; exit 1; }
[ -z "${DREP_INDEX:-}" ] && { echo "DREP_INDEX var must be set"; exit 1; }
[ -z "${POOL_DELEG_ID:-}" ] && { echo "POOL_DELEG_ID var must be set for this use case so that funding this new drep counts towards both the drep and SPO vote classes"; exit 1; }
[ -z "${TESTNET_MAGIC:-}" ] && { echo "TESTNET_MAGIC var must be set"; exit 1; }
[ -z "${THRESHOLD:-}" ] && { echo "THRESHOLD var must be set and most likely should remain the same as the existing threshold"; exit 1; }

export IPFS_GATEWAY_URI="https://ipfs.io"

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

DIR="drep"
mkdir -p "$DIR"

PP=$(cardano-cli query protocol-parameters)
ANCHOR_HASH=$(cardano-cli hash anchor-data --url "$ANCHOR_URL")
COMMITTEE_MAX_LENGTH=$(jq -r '.committeeMaxTermLength' <<< "$PP")
CURRENT_EPOCH=$(cardano-cli query tip | jq .epoch)
DREP_DEPOSIT=$(jq -r '.dRepDeposit' <<< "$PP")
GOV_ACTION_DEPOSIT=$(jq -r '.govActionDeposit' <<< "$PP")
echo "Current epoch on $ENV is: $CURRENT_EPOCH"
echo "Committee maximum length is: $COMMITTEE_MAX_LENGTH"
echo "Drep deposit is: $DREP_DEPOSIT"
echo "Governance action deposit is: $GOV_ACTION_DEPOSIT"

# Create a drep. We should fund any future gov actions after determining
# required stake to pass, so voting power is initially funded only to cover the
# setup and some proposal deposits, ie ~10,000 ADA.
if ! [ -f "$DIR/drep-$DREP_INDEX.addr" ]; then
  echo "Creating drep-$DREP_INDEX"
  DREP_DEPOSIT="$DREP_DEPOSIT" \
    DREP_DIR="$DIR" \
    INDEX="$DREP_INDEX" \
    PAYMENT_KEY="$SCRIPT_DIR/../../secrets/envs/$ENV/utxo-keys/rich-utxo" \
    POOL_DELEG_ID="$POOL_DELEG_ID" \
    STAKE_DEPOSIT="2000000" \
    SUBMIT_TX="false" \
    USE_DECRYPTION="true" \
    USE_ENCRYPTION="false" \
    VOTING_POWER="10000000000" \
    nix run .#job-register-drep
else
  echo "Skipping creation of drep-$DREP_INDEX as it already exists"
fi

# Create a governance update action and submit it.
PROPOSAL_ARGS=(
  "--check-anchor-data"
  "--threshold" "$THRESHOLD"
  "--add-cc-cold-script-hash" "$(cat cc-keys/cc/init-cold/credential.plutus.hash)"
  "--epoch" "$((CURRENT_EPOCH + COMMITTEE_MAX_LENGTH - 1))"
  "--add-cc-cold-script-hash" "$(cat cc-keys/cc2/init-cold/credential.plutus.hash)"
  "--epoch" "$((CURRENT_EPOCH + 15))"
  "--add-cc-cold-script-hash" "$(cat cc-keys/cc3/init-cold/credential.plutus.hash)"
  "--epoch" "$((CURRENT_EPOCH + 15))"
  "--add-cc-cold-script-hash" "$(cat cc-keys/cc4/init-cold/credential.plutus.hash)"
  "--epoch" "$((CURRENT_EPOCH + 15))"
  "--add-cc-cold-script-hash" "$(cat cc-keys/cc5/init-cold/credential.plutus.hash)"
  "--epoch" "$((CURRENT_EPOCH + 15))"
  "--add-cc-cold-script-hash" "$(cat cc-keys/cc6/init-cold/credential.plutus.hash)"
  "--epoch" "$((CURRENT_EPOCH + 15))"
  "--add-cc-cold-script-hash" "$(cat cc-keys/cc7/init-cold/credential.plutus.hash)"
  "--epoch" "$((CURRENT_EPOCH + 15))"
)

ACTION="update-committee" \
  DREP_DIR="$DIR" \
  GOV_ACTION_DEPOSIT="$GOV_ACTION_DEPOSIT" \
  PAYMENT_KEY="$SCRIPT_DIR/../../secrets/envs/$ENV/utxo-keys/rich-utxo" \
  PROPOSAL_HASH="$ANCHOR_HASH" \
  PROPOSAL_URL="$ANCHOR_URL" \
  STAKE_KEY="$DIR/stake-$DREP_INDEX" \
  SUBMIT_TX="false" \
  USE_DECRYPTION="true" \
  USE_ENCRYPTION="false" \
  nix run .#job-submit-gov-action -- "${PROPOSAL_ARGS[@]}"
