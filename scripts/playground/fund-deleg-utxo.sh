#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

FUND_DELEGATE() {
  NAME="$1"
  SEND_ADDR="$2"

  read -p "Do you wish to fund $NAME [yY]? " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -r -p "Enter in lovelace what the funding UTXO should be: " LOVELACE
    just fund-transfer "$ENV" "$SEND_ADDR" "$LOVELACE"
  fi
  echo
}

echo "In env $ENV, pool1 currently has UTXO of:"
cardano-cli latest query utxo --address "$(just sops-decrypt-binary "secrets/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-payment-stake.addr")" | jq
echo
FUND_DELEGATE "pool1" "$(just sops-decrypt-binary "secrets/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-owner-payment-stake.addr")"

echo "In env $ENV, pool2 currently has UTXO of:"
cardano-cli latest query utxo --address "$(just sops-decrypt-binary "secrets/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-owner-payment-stake.addr")" | jq
echo
FUND_DELEGATE "pool2" "$(just sops-decrypt-binary "secrets/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-owner-payment-stake.addr")"

echo "In env $ENV, pool3 currently has UTXO of:"
cardano-cli latest query utxo --address "$(just sops-decrypt-binary "secrets/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-owner-payment-stake.addr")" | jq
echo
FUND_DELEGATE "pool3" "$(just sops-decrypt-binary "secrets/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-owner-payment-stake.addr")"

echo "In env $ENV, drep-0 currently has UTXO of:"
cardano-cli latest query utxo --address "$(just sops-decrypt-binary "secrets/envs/${ENV}/drep/drep-0.addr")" | jq
echo
FUND_DELEGATE "drep-0" "$(just sops-decrypt-binary "secrets/envs/${ENV}/drep/drep-0.addr")"
