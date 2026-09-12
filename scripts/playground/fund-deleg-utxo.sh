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

Funds each pool owner payment address in \$ENV, then the drep.  With no args
every discovered group is offered.  Naming a group, or several, restricts the
run to those, which is useful now that an env may hold many pools:

  ENV=leios $(basename "$0")                      # all leios* groups
  ENV=leios $(basename "$0") leiosred4 leiosred5  # just these two

Run from the repo root.  Each pool prompts y/N individually before any
transfer, so an unexpected entry in the list can simply be declined.
EOF
  exit 1
}

[[ " $* " == *" --help "* || " $* " == *" -h "* ]] && USAGE

FUND_DELEGATE() {
  NAME="$1"
  SEND_ADDR="$2"

  echo "In env $ENV, $NAME currently has UTXO of:"
  cardano-cli latest query utxo --address "$SEND_ADDR" | jq
  echo

  # [y/N] rather than [yY]: shows that declining is an option and that it is
  # the default.  Any key other than y, including plain enter, skips.
  read -p "Fund $NAME? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -r -p "Enter in lovelace what the funding UTXO should be: " LOVELACE
    if [[ ! $LOVELACE =~ ^[1-9][0-9]*$ ]]; then
      echo "Not a positive integer lovelace amount, skipping $NAME." >&2
    else
      just fund-transfer "$ENV" "$SEND_ADDR" "$LOVELACE"
    fi
  else
    echo "Skipped $NAME, nothing sent."
  fi
  echo
}

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

echo "Pools to be offered for funding in env $ENV:"
printf '%s\n' "${ADDR_FILES[@]}" | cut -d/ -f3 | sed 's/^/  /'
echo

for FILE in "${ADDR_FILES[@]}"; do
  GROUP=$(cut -d/ -f3 <<< "$FILE")
  # Decrypted once and reused, rather than once to display and again to fund.
  ADDR=$(just sops-decrypt-binary "$FILE")
  FUND_DELEGATE "$GROUP" "$ADDR"
done

DREP_ADDR=$(just sops-decrypt-binary "secrets/envs/${ENV}/drep/drep-0.addr")
FUND_DELEGATE "drep-0" "$DREP_ADDR"
