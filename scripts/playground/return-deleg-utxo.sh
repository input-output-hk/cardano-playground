#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

PICK_UTXO() {
  ID="$1"
  SEND_ADDR="$2"

  echo "From the $ID sender account the following lovelace only UTXO are available to return:"
  cardano-cli latest query utxo --address "$SEND_ADDR" | jq
  echo
  read -r -p "Enter the UTXO to return or hit enter to skip: " UTXO
}

RICH_ADDR=$(just sops-decrypt-binary "secrets/envs/${ENV}/utxo-keys/rich-utxo.addr")
RICH_SKEY=$(just sops-decrypt-binary "secrets/envs/${ENV}/utxo-keys/rich-utxo.skey")

if [ -z "${DISABLE_POOL_RETURN:-}" ]; then
  PICK_UTXO "pool1" "$(just sops-decrypt-binary "secrets/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-payment-stake.addr")"
  [ -n "$UTXO" ] \
    && return-utxo "$ENV" "$RICH_ADDR" "$UTXO" <(echo "$RICH_SKEY") <(just sops-decrypt-binary "secrets/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-stake.skey")

  PICK_UTXO "pool2" "$(just sops-decrypt-binary "secrets/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-owner-payment-stake.addr")"
  [ -n "$UTXO" ] \
    && return-utxo "$ENV" "$RICH_ADDR" "$UTXO" <(echo "$RICH_SKEY") <(just sops-decrypt-binary "secrets/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-owner-stake.skey")

  PICK_UTXO "pool3" "$(just sops-decrypt-binary "secrets/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-owner-payment-stake.addr")"
  [ -n "$UTXO" ] \
    && return-utxo "$ENV" "$RICH_ADDR" "$UTXO" <(echo "$RICH_SKEY") <(just sops-decrypt-binary "secrets/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-owner-stake.skey")
fi

if [ -z "${DISABLE_DREP_RETURN:-}" ]; then
  PICK_UTXO "drep-0" "$(just sops-decrypt-binary "secrets/envs/${ENV}/drep/drep-0.addr")"
  [ -n "$UTXO" ] \
    && return-utxo "$ENV" "$RICH_ADDR" "$UTXO" \
      <(just sops-decrypt-binary "secrets/envs/$ENV/drep/pay-0.skey") \
      <(just sops-decrypt-binary "secrets/envs/$ENV/drep/stake-0.skey")
fi
