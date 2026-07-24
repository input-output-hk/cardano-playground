#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

[ -z "${ANCHOR_URL:-}" ] && { echo "ANCHOR_URL var must be set and should point to an ipfs://\$CIDv0 address"; exit 1; }
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
#
# Committee cold credentials are scripts, so removals must use
# --remove-cc-cold-script-hash; the key-hash flag builds a key credential
# that silently no-ops at enactment.
case "$ENV" in
  preview)
    REMOVE_CC_SCRIPT_HASHES=(
      "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/cc4/init-cold/credential.plutus.hash")"
      "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/cc5/init-cold/credential.plutus.hash")"
      "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/cc6/init-cold/credential.plutus.hash")"
      "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/cc7/init-cold/credential.plutus.hash")"
      "$(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/icc-keys/init-cold/credential.plutus.hash")"
    )
    ;;
  preprod)
    # Cold script hashes are public on-chain data; several of these expired
    # members pre-date our tenure and have no local secrets.  The 11 expired
    # members as of epoch 297 (expirations 229 and 242), from:
    #   cardano-cli latest query committee-state \
    #     | jq -r '.committee | to_entries[]
    #         | select(.value.status == "Expired")
    #         | .key | ltrimstr("scriptHash-")'
    REMOVE_CC_SCRIPT_HASHES=(
      "2f4a6c6f098e20ee4bfd5b39942c164575f8ceb348e754df5d0ec04f"
      "3061a5d942665fc3cac6d38bac91c4f0272c4bc2b353e48633a63747"
      "5098dfd0deba725fadd692198fc33ee959fbe7e6edf1b5a695e06e61"
      "5a71f17f4ce4c1c0be053575d717ade6ad8a1d5453d02a65ce40d4b1"
      "6095e643ea6f1cccb6e463ec34349026b3a48621aac5d512655ab1bf"
      "70d20c66e0d63c9a638d9230310b4fba988f620ab1a41654e66f167c"
      "78299eeac0e8caa9739efde7963721627d74b668720ece7dce0e21cb"
      "94c0de47e7ae32e3f7234ada5cf976506b68e3bb88c54dc53b4ba984"
      "94f51c795a6c11adb9c1e30f0b6def4230cbd0b8bc800098e2d2307b"
      "a6a5e006fd4e8f51062dc431362369b2a43140abced8aa2ff2256d7b"
      "ca2abaada6624580938c8da0be4253d4e837c7aabb307a3acc444b48"
    )
    ;;
  *)
    echo "No expired CC member removal list is defined for ENV=$ENV"
    exit 1
    ;;
esac

PROPOSAL_ARGS=(
  "--prev-governance-action-tx-id" "$PREV_GOV_ACTION_TX_ID"
  "--prev-governance-action-index" "$PREV_GOV_ACTION_INDEX"
  "--check-anchor-data"
  "--threshold" "$THRESHOLD"
)

for SCRIPT_HASH in "${REMOVE_CC_SCRIPT_HASHES[@]}"; do
  PROPOSAL_ARGS+=("--remove-cc-cold-script-hash" "$SCRIPT_HASH")
done

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
