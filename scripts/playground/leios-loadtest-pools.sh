#! /usr/bin/env bash

# Create and register N throwaway pools whose only purpose is to carry a BLS
# key into a voting load test. They do not forge, carry no pledge and advertise
# no relay, so everything the normal pool flow does beyond the registration
# certificate is skipped. Set POOL_METADATA_URL to point them all at one
# metadata file saying what they are.
#
# Each pool still registers and delegates its own owner stake address, since the
# job emits those certs, but with POOL_PLEDGE=0 nothing is paid to that address,
# so the delegation carries no stake and the pool's committee weight is zero.
#
# Secrets land under workbench/, which is gitignored. Keep a backup of that
# tree: the cold keys are the only way to retire these pools afterwards and
# reclaim the deposits.
#
# Subcommands:
#   keys      generate cold/vrf/kes/bls keys, one directory per batch
#   register  build, size-check, submit and confirm one tx per batch
#   bls       assemble the per-machine load test key arrays
#   merge     prepend each machine's own key and install, keeping a backup
#   restore   put the original machine keys back
#   retire    build retirement certificates for every pool
#   status    show per-batch progress
#
# Resumable: a batch that already recorded a txid is skipped.

set -euo pipefail

TOTAL=${TOTAL:-750}
MACHINES=${MACHINES:-10}
WORKDIR=${WORKDIR:-workbench/leios-loadtest}
NAME_PREFIX=${NAME_PREFIX:-lt}

# Default to whatever this workdir was built with, so a bare status reports the
# real layout. A fixed default silently disagrees once a run uses another size,
# and the batch count it reports is then wrong rather than merely stale.
BATCH=${BATCH:-$(cat "$WORKDIR/.batch-size" 2>/dev/null || echo 20)}

export ENV=${ENV:-leios}
export TESTNET_MAGIC=${TESTNET_MAGIC:-164}
export ERA_CMD=${ERA_CMD:-dijkstra}
export USE_BLS=true

# Throwaway pool keys stay plaintext in a gitignored tree, so nothing is
# encrypted on the way out. Decryption still has to be on: the funding key under
# secrets/envs is sops encrypted and the job has to read it to sign. The job's
# decrypt_check passes an unencrypted file straight through, so the workbench
# keys are unaffected by this.
export USE_ENCRYPTION=false
export USE_DECRYPTION=true
export UNSTABLE=false
export USE_SHELL_BINS=true

export CARDANO_NODE_SOCKET_PATH=${CARDANO_NODE_SOCKET_PATH:-$PWD/node.socket}
PAYMENT_KEY=${PAYMENT_KEY:-secrets/envs/$ENV/utxo-keys/rich-utxo}

# No pledge: a declared pledge only affects rewards, and seat selection ranks
# on active stake, which these pools deliberately have none of.
POOL_PLEDGE=0
# Protocol minimum; declared only, never spent.
POOL_COST=${POOL_COST:-170000000}
# No relay, unlike the one-off pool flow. Nothing dials these pools: their keys
# vote from the leiosred machines, and the cert's relay list is optional in both
# the cli and the ledger. An address here would publish 750 entries into every
# peer's topology for the life of the registration, aimed at a host that either
# does not want the traffic or does not exist.
POOL_RELAY=${POOL_RELAY:-}
POOL_RELAY_PORT=${POOL_RELAY_PORT:-}
# One metadata file shared by every load test pool, so anyone reading the pool
# list can see what these are and why they exist. POOL_METADATA_URL rather than
# POOL_METADATA_BASE_URL: the latter derives a per-pool file from the name's
# first dash delimited token, which for lt001 would ask for lt001.json.
#
# The job curls this at cert build time to hash it, so deploy
# misc1-webserver-a-1 with static/pools.play.dev.cardano.org/leios-loadtest.json
# before registering, as with any other new pool.
POOL_METADATA_URL=${POOL_METADATA_URL:-https://pools.play.dev.cardano.org/leios-loadtest.json}
# The job defaults to 300000, which is below the minimum for a tx this size.
# Overpaying is harmless here and avoids a rebuild per batch.
FEE=${FEE:-2000000}
# SUBMIT=false builds the first pending batch, size checks it and stops without
# sending, for inspecting a transaction before committing to the run.
SUBMIT=${SUBMIT:-true}

BATCHES=$(( (TOTAL + BATCH - 1) / BATCH ))

# TOTAL may grow between runs, so a 25 pool smoke test resumes cleanly into the
# full 750. BATCH may not: it decides which pools live in which batch directory,
# so changing it would point the existing skip markers at a different pool set.
check-batch-size() {
  local f="$WORKDIR/.batch-size"
  mkdir -p "$WORKDIR"
  if [ -f "$f" ] && [ "$(cat "$f")" != "$BATCH" ]; then
    echo "BATCH is $BATCH but $WORKDIR was built with $(cat "$f")." >&2
    echo "Re-run with BATCH=$(cat "$f"), or use a fresh WORKDIR." >&2
    exit 1
  fi
  echo "$BATCH" > "$f"
}

# The jobs run with USE_SHELL_BINS=true, so they take cardano-cli from PATH,
# and only the leios pin has the dijkstra era and BLS support. Sourced inside a
# function so the pin script sees no positional arguments: at top level it would
# read this script's subcommand as its own, and "-u" would unpin instead.
pin-cli() {
  . scripts/playground/leios-pin.sh
}

pool-names() {
  # Batch $1, 1-indexed, as a space delimited name list.
  local b=$1 start end i out=()
  start=$(( (b - 1) * BATCH + 1 ))
  end=$(( b * BATCH ))
  [ "$end" -gt "$TOTAL" ] && end=$TOTAL
  for ((i = start; i <= end; i++)); do
    out+=("$(printf '%s%03d' "$NAME_PREFIX" "$i")")
  done
  echo "${out[@]}"
}

batch-dir() { printf '%s/batch-%02d' "$WORKDIR" "$1"; }

max-tx-size() {
  cardano-cli latest query protocol-parameters --testnet-magic "$TESTNET_MAGIC" | jq -r .maxTxSize
}

# The job has decrypt_check for this, but it only exists inside the job scripts,
# so repeat the same test here: sops encrypted files carry a sops key and a data
# key, anything else is already plaintext.
plaintext() {
  if jq -e 'has("sops") and has("data")' "$1" > /dev/null 2>&1; then
    sops -d "$1"
  else
    cat "$1"
  fi
}

change-address() {
  cardano-cli latest address build \
    --payment-verification-key-file <(plaintext "$PAYMENT_KEY".vkey) \
    --testnet-magic "$TESTNET_MAGIC"
}

# Wait until a submitted tx is visible on chain. scripts/bash-fns.sh only has
# wait-for-mempool, which needs an idle mempool and so only works in the load
# generator's off hour; this polls for the tx's own change output instead and
# is safe to run under load.
wait-for-txid() {
  local txid=$1 addr=$2 tries=${3:-120}
  local i
  for ((i = 0; i < tries; i++)); do
    if cardano-cli latest query utxo --address "$addr" --testnet-magic "$TESTNET_MAGIC" \
      | jq -e --arg t "$txid" 'keys[] | select(startswith($t))' >/dev/null 2>&1; then
      echo "  confirmed $txid"
      return 0
    fi
    sleep 5
  done
  echo "  TIMEOUT waiting for $txid; check the chain before re-running" >&2
  return 1
}

cmd-keys() {
  check-batch-size
  pin-cli
  local slot slots_per_kes b dir names
  slot=$(just query-tip "$ENV" | jq .slot)
  slots_per_kes=$(jq -r .slotsPerKESPeriod < "docs/environments-pre/$ENV/shelley-genesis.json")
  export CURRENT_KES_PERIOD=$(( slot / slots_per_kes ))

  for ((b = 1; b <= BATCHES; b++)); do
    dir=$(batch-dir "$b")
    names=$(pool-names "$b")
    if [ -f "$dir/.keys" ]; then
      echo "batch $b: keys present, skipping"
      continue
    fi
    echo "batch $b: generating keys for $(wc -w <<< "$names") pools"
    mkdir -p "$dir"
    # Each batch gets its own STAKE_POOL_DIR, so each batch also gets its own
    # shared reward account. One dir for all 750 would mean batch 2 onward
    # re-registering an already registered reward stake address.
    STAKE_POOL_DIR=$dir POOL_NAMES="$names" nix run .#job-create-stake-pool-keys
    touch "$dir/.keys"
  done
}

cmd-register() {
  check-batch-size
  pin-cli
  local maxsize addr b dir names first size txid
  maxsize=$(max-tx-size)
  addr=$(change-address)
  echo "max tx size $maxsize, funding from $addr"

  for ((b = 1; b <= BATCHES; b++)); do
    dir=$(batch-dir "$b")
    names=$(pool-names "$b")
    first=$(awk '{print $1}' <<< "$names")

    if [ -f "$dir/.registered" ]; then
      echo "batch $b: already registered as $(cat "$dir/.registered"), skipping"
      continue
    fi
    [ -f "$dir/.keys" ] || { echo "batch $b: no keys yet, run the keys subcommand first" >&2; exit 1; }

    echo "batch $b: building tx for $(wc -w <<< "$names") pools"
    STAKE_POOL_DIR=$dir \
    POOL_NAMES="$names" \
    POOL_PLEDGE=$POOL_PLEDGE \
    POOL_COST=$POOL_COST \
    POOL_RELAY=$POOL_RELAY \
    POOL_RELAY_PORT=$POOL_RELAY_PORT \
    POOL_METADATA_URL=$POOL_METADATA_URL \
    FEE=$FEE \
    PAYMENT_KEY=$PAYMENT_KEY \
    SUBMIT_TX=false \
      nix run .#job-register-stake-pools

    # Measure the cbor, not the file. A .txsigned is a json envelope holding the
    # transaction as a hex string, so the file on disk is about twice the size
    # the protocol limit applies to.
    size=$(( $(jq -r .cborHex "$first-tx-pool-reg.txsigned" | tr -d '\n' | wc -c) / 2 ))
    echo "  tx size $size of $maxsize"
    if [ "$size" -gt "$maxsize" ]; then
      echo "  tx exceeds maxTxSize; lower BATCH and re-run" >&2
      exit 1
    fi

    # --output-text for a bare hash: this cli defaults to a json object, which
    # would go into the confirmation match and the .registered marker verbatim.
    txid=$(cardano-cli latest transaction txid --tx-file "$first-tx-pool-reg.txsigned" --output-text)

    if [ "$SUBMIT" != "true" ]; then
      # Stop at one batch. Every later batch spends the change of the one before
      # it, so with nothing submitted they would all contend for the same utxo
      # and build conflicting transactions.
      echo "  built, not submitted: $first-tx-pool-reg.txsigned"
      echo "  txid $txid"
      echo "  inspect: cardano-cli debug transaction view --tx-file $first-tx-pool-reg.txsigned"
      echo "  batch left unmarked, so a later run with SUBMIT=true rebuilds and sends it"
      return 0
    fi

    cardano-cli latest transaction submit --testnet-magic "$TESTNET_MAGIC" \
      --tx-file "$first-tx-pool-reg.txsigned"
    echo "  submitted $txid"

    # Each batch spends the previous batch's change, so confirm before moving on.
    wait-for-txid "$txid" "$addr"

    # Marked as soon as it confirms, before the moves below: a crash in between
    # must not leave a resume that re-registers pools already on chain.
    echo "$txid" > "$dir/.registered"

    mkdir -p "$dir/tx"
    mv "$first"-tx-pool-reg.* "$dir/tx/"
    for n in $names; do mv "$n"-*.cert "$dir/tx/" 2>/dev/null || true; done
  done
}

cmd-bls() {
  check-batch-size
  # Split the load test pools evenly across the forging machines, one JSON array
  # of BLS signing key envelopes each. These arrays are not deployable as they
  # stand: the machine's own key has to go in too, which is what merge does.
  #
  # w40a takes a single --shelley-bls-key file that is either one envelope or a
  # JSON array of them, and votes with every key in it that holds a seat, so the
  # array is the whole of a machine's voting identity. Overwriting a machine's
  # key file with only these would take its real pool out of the committee.
  local per out i n idx dir name files=()
  mkdir -p "$WORKDIR/bls"
  for ((n = 1; n <= TOTAL; n++)); do
    name=$(printf '%s%03d' "$NAME_PREFIX" "$n")
    idx=$(( (n - 1) / BATCH + 1 ))
    dir=$(batch-dir "$idx")
    files+=("$dir/deploy/$name-bls.skey")
  done

  per=$(( (TOTAL + MACHINES - 1) / MACHINES ))
  for ((i = 0; i < MACHINES; i++)); do
    out="$WORKDIR/bls/leiosred$((i + 1))-bls-keys.json"
    jq -s . "${files[@]:$((i * per)):$per}" > "$out"
    echo "$out: $(jq length < "$out") keys"
  done
}

cmd-merge() {
  check-batch-size
  # Put each machine's own BLS key at the head of its load test array and write
  # the result back over the machine's key file, re-encrypted. The original is
  # kept, still encrypted, so the fleet can be put back afterwards.
  #
  # Own key first so the array reads as "this pool, plus the synthetic ones".
  # Order has no effect on voting: the node tries every key against every seat.
  local n dir own base backup merged count
  mkdir -p "$WORKDIR/bls/backup"
  for ((n = 1; n <= MACHINES; n++)); do
    dir="secrets/groups/leiosred$n/deploy"
    # Glob rather than reconstruct the name: the availability zone letter in
    # leiosredN-bp-<az>-1 does not track N.
    own=$(echo "$dir"/*-bls.skey)
    if [ ! -f "$own" ]; then
      echo "leiosred$n: no bls key at $dir, skipping" >&2
      continue
    fi
    base=$(basename "$own")
    backup="$WORKDIR/bls/backup/$base.orig"
    merged="$WORKDIR/bls/leiosred$n-bls-keys.json"
    [ -f "$merged" ] || { echo "leiosred$n: run the bls subcommand first" >&2; exit 1; }

    # Copied in its encrypted form, so no plaintext copy is made here.
    [ -f "$backup" ] || cp "$own" "$backup"

    jq -s '[.[0]] + .[1]' <(sops -d "$own") "$merged" > "$merged.tmp"
    count=$(jq length < "$merged.tmp")
    mv "$merged.tmp" "$merged"

    cp "$merged" "$own"
    sops -e -i "$own"
    echo "leiosred$n: $base now carries $count keys, original at $backup"
  done
  echo
  echo "Deploy to pick these up. Restore with: cp $WORKDIR/bls/backup/<name>.orig <deploy path>"
}

cmd-restore() {
  # Put the untouched, still encrypted originals back.
  local f base n dir
  for f in "$WORKDIR"/bls/backup/*-bls.skey.orig; do
    [ -f "$f" ] || { echo "no backups in $WORKDIR/bls/backup"; return 0; }
    base=$(basename "$f" .orig)
    n=${base%%-*}
    dir="secrets/groups/$n/deploy"
    cp "$f" "$dir/$base"
    echo "restored $dir/$base"
  done
}

cmd-retire() {
  check-batch-size
  # Retirement certificates for every pool, so the deposits can be reclaimed.
  # Needs the cold keys, which is why the workbench tree is worth backing up.
  pin-cli
  local epoch b dir names n
  epoch=$(( $(just query-tip "$ENV" | jq .epoch) + 1 ))
  mkdir -p "$WORKDIR/retire"
  for ((b = 1; b <= BATCHES; b++)); do
    dir=$(batch-dir "$b")
    names=$(pool-names "$b")
    for n in $names; do
      cardano-cli latest stake-pool deregistration-certificate \
        --cold-verification-key-file "$dir/no-deploy/$n-cold.vkey" \
        --epoch "$epoch" \
        --out-file "$WORKDIR/retire/$n-retire.cert"
    done
  done
  echo "retirement certs for epoch $epoch in $WORKDIR/retire"
}

cmd-status() {
  local b dir
  printf '%-10s %-8s %s\n' batch keys registered
  for ((b = 1; b <= BATCHES; b++)); do
    dir=$(batch-dir "$b")
    printf '%-10s %-8s %s\n' "$b" \
      "$([ -f "$dir/.keys" ] && echo yes || echo no)" \
      "$([ -f "$dir/.registered" ] && cat "$dir/.registered" || echo no)"
  done
}

case "${1:-}" in
  keys) cmd-keys ;;
  register) cmd-register ;;
  bls) cmd-bls ;;
  merge) cmd-merge ;;
  restore) cmd-restore ;;
  retire) cmd-retire ;;
  status) cmd-status ;;
  *)
    echo "usage: $0 {keys|register|bls|merge|restore|retire|status}"
    echo "  TOTAL=$TOTAL BATCH=$BATCH -> $BATCHES batches, MACHINES=$MACHINES"
    exit 1
    ;;
esac
