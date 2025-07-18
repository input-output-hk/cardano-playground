#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

[ -z "${RATIONALE_FILE:-}" ] && { echo "RATIONALE_FILE var must be set"; exit 1; }

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

PICK_UTXO() {
  SEND_ADDR="$1"

  echo "From the sender account the following lovelace only UTXO are available to return:"
  cardano-cli latest query utxo --address "$SEND_ADDR"
  read -r -p "Enter the return to return: " UTXO
}

RICH_ADDR=$(just sops-decrypt-binary "secrets/envs/${ENV}/utxo-keys/rich-utxo.addr")
RICH_SKEY=$(just sops-decrypt-binary "secrets/envs/${ENV}/utxo-keys/rich-utxo.skey")

if [ -z "${DISABLE_POOL_RETURN:-}" ]; then
  PICK_UTXO "$(just sops-decrypt-binary "secrets/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-payment-stake.addr")"
  return-utxo "$ENV" "$RICH_ADDR" "$UTXO" "$RICH_SKEY" <(just sops-decrypt-binary "secrets/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-stake.skey")

  PICK_UTXO "$(just sops-decrypt-binary "secrets/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-owner-payment-stake.addr")"
  return-utxo "$ENV" "$RICH_ADDR" "$UTXO" "$RICH_SKEY" <(just sops-decrypt-binary "secrets/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-owner-stake.skey")

  PICK_UTXO "$(just sops-decrypt-binary "secrets/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-owner-payment-stake.addr")"
  return-utxo "$ENV" "$RICH_ADDR" "$UTXO" "$RICH_SKEY" <(just sops-decrypt-binary "secrets/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-owner-stake.skey")
fi

if [ -z "${DISABLE_DREP_RETURN:-}" ]; then
  PICK_UTXO "$(just sops-decrypt-binary "secrets/envs/${ENV}/drep/drep.addr")"
  return-utxo "$ENV" "$RICH_ADDR" "$UTXO" \
    <(just sops-decrypt-binary "secrets/envs/$ENV/drep/pay-0.skey") \
    <(just sops-decrypt-binary "secrets/envs/$ENV/drep/stake-0.skey")
fi
