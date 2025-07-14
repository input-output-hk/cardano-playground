#!/usr/bin/env bash
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

[ -z "${ACTION_ID:-}" ] && { echo "ACTION_ID var must be set"; exit 1; }
[ -z "${ACTION_IDX:-}" ] && { echo "ACTION_IDX var must be set"; exit 1; }

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

cardano-cli latest governance vote create \
    --yes \
    --governance-action-tx-id "$ACTION_ID" \
    --governance-action-index "$ACTION_IDX" \
    --cold-verification-key-file <(just sops-decrypt-binary "secrets/groups/${ENV}1/deploy/${ENV}1-bp-a-1-cold.vkey") \
    --out-file "$ACTION_ID-${ENV}-pool-1.vote"

cardano-cli latest governance vote create \
    --yes \
    --governance-action-tx-id "$ACTION_ID" \
    --governance-action-index "$ACTION_IDX" \
    --cold-verification-key-file <(just sops-decrypt-binary "secrets/groups/${ENV}2/deploy/${ENV}2-bp-b-1-cold.vkey") \
    --out-file "$ACTION_ID-${ENV}-pool-2.vote"

cardano-cli latest governance vote create \
    --yes \
    --governance-action-tx-id "$ACTION_ID" \
    --governance-action-index "$ACTION_IDX" \
    --cold-verification-key-file <(just sops-decrypt-binary "secrets/groups/${ENV}3/deploy/${ENV}3-bp-c-1-cold.vkey") \
    --out-file "$ACTION_ID-${ENV}-pool-3.vote"

cardano-cli latest governance vote create \
    --yes \
    --governance-action-tx-id "$ACTION_ID" \
    --governance-action-index "$ACTION_IDX" \
    --drep-verification-key-file <(just sops-decrypt-binary "secrets/envs/${ENV}/drep/drep-0.vkey") \
    --out-file "$ACTION_ID-${ENV}-drep-0.vote"

RICH_ADDR=$(just sops-decrypt-binary "secrets/envs/${ENV}/utxo-keys/rich-utxo.addr")

TXIN=$(cardano-cli latest query utxo \
  --address "$RICH_ADDR" \
  --out-file /dev/stdout \
  | jq -r '.
    | to_entries
    | map(select(.value.value.lovelace > 5000000))
    | sort_by(.value.value.lovelace)[0].key')

# Build the transaction:
cardano-cli latest transaction build \
  --tx-in "$TXIN" \
  --change-address "$RICH_ADDR" \
  --testnet-magic "$TESTNET_MAGIC" \
  --vote-file "$ACTION_ID-${ENV}-pool-1.vote" \
  --vote-file "$ACTION_ID-${ENV}-pool-2.vote" \
  --vote-file "$ACTION_ID-${ENV}-pool-3.vote" \
  --vote-file "$ACTION_ID-${ENV}-drep-0.vote" \
  --witness-override 5 \
  --out-file vote-tx.raw

# Sign the transaction:
cardano-cli latest transaction sign \
  --tx-body-file vote-tx.raw \
  --signing-key-file <(just sops-decrypt-binary "secrets/envs/${ENV}/utxo-keys/rich-utxo.skey") \
  --signing-key-file <(just sops-decrypt-binary "secrets/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-cold.skey") \
  --signing-key-file <(just sops-decrypt-binary "secrets/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-cold.skey") \
  --signing-key-file <(just sops-decrypt-binary "secrets/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-cold.skey") \
  --signing-key-file <(just sops-decrypt-binary "secrets/envs/${ENV}/drep/drep-0.skey") \
  --testnet-magic "$TESTNET_MAGIC" \
  --out-file vote-tx.signed
