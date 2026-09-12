#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

USAGE() {
  cat >&2 <<EOF
Usage: ENV=<env> $(basename "$0") [group ...]

Returns delegated UTXO from each pool owner payment address in \$ENV to the rich
key, then from the drep.  With no args every discovered group is offered.  Naming
a group, or several, restricts the run to those, which is useful now that an env
may hold many pools:

  ENV=leios $(basename "$0")                      # all leios* groups
  ENV=leios $(basename "$0") leiosred4 leiosred5  # just these two

Env toggles:
  DISABLE_POOL_RETURN=1   skip the pools entirely
  DISABLE_DREP_RETURN=1   skip the drep

Run from the repo root.  Each pool lists its UTXO and waits for one to be named,
so an unexpected entry in the list can be skipped by hitting enter.
EOF
  exit 1
}

[[ " $* " == *" --help "* || " $* " == *" -h "* ]] && USAGE

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
  # One owner payment address per group, on the bp host, at
  #   secrets/groups/<group>/no-deploy/<group>-bp-<az>-1-owner-payment-stake.addr
  # Discovered rather than hardcoded so groups added later are picked up without
  # editing this script, and so the bp az letter never has to be spelled out.  For
  # ENV=leios this intentionally matches the leiosred* pools too, since they share
  # the leios environment.  sort -V keeps leiosred10 after leiosred9.
  shopt -s nullglob
  FOUND=(secrets/groups/"${ENV}"*/no-deploy/*-bp-*-owner-payment-stake.addr)
  shopt -u nullglob

  if [ "${#FOUND[@]}" -eq 0 ]; then
    echo "No pool owner payment addresses found under secrets/groups/${ENV}*/no-deploy/" >&2
    echo "Check ENV is correct and that this is being run from the repo root." >&2
    exit 1
  fi

  mapfile -t ADDR_FILES < <(printf '%s\n' "${FOUND[@]}" | sort -V)

  # job-register-stake-pools writes exactly one of these per registered pool, so
  # more than one per group means key material this script cannot disambiguate.
  # Stop rather than silently offering an extra address.
  DUPES=$(printf '%s\n' "${ADDR_FILES[@]}" | cut -d/ -f3 | sort | uniq -d)
  if [ -n "$DUPES" ]; then
    echo "More than one bp owner payment address found for group(s): $DUPES" >&2
    echo "Refusing to guess which belongs to the registered pool." >&2
    exit 1
  fi

  # Restrict to groups named on the command line, if any were.
  if [ "$#" -gt 0 ]; then
    KEEP=()
    for FILE in "${ADDR_FILES[@]}"; do
      GROUP=$(cut -d/ -f3 <<< "$FILE")
      for WANT in "$@"; do
        [ "$GROUP" = "$WANT" ] && KEEP+=("$FILE") && break
      done
    done

    for WANT in "$@"; do
      printf '%s\n' "${ADDR_FILES[@]}" | cut -d/ -f3 | grep -qxF "$WANT" \
        || { echo "No such group for env $ENV: $WANT" >&2; USAGE; }
    done

    ADDR_FILES=("${KEEP[@]}")
  fi

  echo "Pools to be offered for return in env $ENV:"
  printf '%s\n' "${ADDR_FILES[@]}" | cut -d/ -f3 | sed 's/^/  /'
  echo

  for FILE in "${ADDR_FILES[@]}"; do
    GROUP=$(cut -d/ -f3 <<< "$FILE")
    # The owner stake skey signs the return.  Derived from the addr path rather
    # than globbed: some groups hold owner keys for more than one host, so a
    # glob is ambiguous while this substitution is exact.
    SKEY="${FILE%-owner-payment-stake.addr}-owner-stake.skey"

    if [ ! -f "$SKEY" ]; then
      echo "Skipping $GROUP, no owner stake skey at $SKEY" >&2
      echo
      continue
    fi

    PICK_UTXO "$GROUP" "$(just sops-decrypt-binary "$FILE")"

    if [ -n "$UTXO" ]; then
      # skeys stay in process substitution, never in a variable or on disk
      return-utxo "$ENV" "$RICH_ADDR" "$UTXO" \
        <(echo "$RICH_SKEY") \
        <(just sops-decrypt-binary "$SKEY")
    else
      echo "Skipped $GROUP, nothing returned."
    fi
    echo
  done
fi

if [ -z "${DISABLE_DREP_RETURN:-}" ]; then
  PICK_UTXO "drep-0" "$(just sops-decrypt-binary "secrets/envs/${ENV}/drep/drep-0.addr")"

  if [ -n "$UTXO" ]; then
    return-utxo "$ENV" "$RICH_ADDR" "$UTXO" \
      <(just sops-decrypt-binary "secrets/envs/$ENV/drep/pay-0.skey") \
      <(just sops-decrypt-binary "secrets/envs/$ENV/drep/stake-0.skey")
  else
    echo "Skipped drep-0, nothing returned."
  fi
fi
