#!/usr/bin/env bash
# Build a fake tx for misc testing, example: cardano-submit-api.
# Structurally valid + genuinely signed, but spends a nonexistent input,
# so the node rejects it with BadInputsUTxO -- exercises the full
# submit-api -> node path rather than just the CBOR decoder.
#
# Run from a shell with cardano-cli.
#
# The output address carries a network id in its header byte.
#
#   NETWORK=mainnet ./mk-faketx.sh      # -> tx-mainnet.cbor  (default)
#   NETWORK=preprod ./mk-faketx.sh      # -> tx-preprod.cbor
#   NETWORK=preview ./mk-faketx.sh      # -> tx-preview.cbor
#   NETWORK=42      ./mk-faketx.sh      # any other testnet magic
#
# Other overrides: OUT, PREFIX, TXIN, LOVELACE, FEE

set -euo pipefail

OUT=${OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
NETWORK=${NETWORK:-mainnet}
PREFIX=${PREFIX:-tx-$NETWORK}
TXIN=${TXIN:-1122334455667788112233445566778811223344556677881122334455667788#0}
LOVELACE=${LOVELACE:-1000000}
FEE=${FEE:-180000}

case "$NETWORK" in
  mainnet)     NETARG=(--mainnet) ;;
  preprod)     NETARG=(--testnet-magic 1) ;;
  preview)     NETARG=(--testnet-magic 2) ;;
  *[!0-9]*|'') echo "NETWORK must be mainnet|preprod|preview|<magic>, got '$NETWORK'" >&2; exit 1 ;;
  *)           NETARG=(--testnet-magic "$NETWORK") ;;
esac

cd "$OUT"

# Payment keys are network-independent, so one pair serves every network.
[ -f pay.skey ] || cardano-cli address key-gen \
  --verification-key-file pay.vkey --signing-key-file pay.skey

ADDR=$(cardano-cli address build --payment-verification-key-file pay.vkey "${NETARG[@]}")

cardano-cli conway transaction build-raw \
  --tx-in "$TXIN" \
  --tx-out "$ADDR+$LOVELACE" \
  --fee "$FEE" \
  --out-file "$PREFIX.raw"

# NETARG here only affects Byron witnesses; harmless but keeps intent explicit.
cardano-cli conway transaction sign \
  --tx-body-file "$PREFIX.raw" --signing-key-file pay.skey \
  "${NETARG[@]}" --out-file "$PREFIX.signed"

HEX=$(jq -r .cborHex "$PREFIX.signed")
printf '%s\n' "$HEX" > "$PREFIX.hex"
printf "$(printf '%s' "$HEX" | sed 's/../\\x&/g')" > "$PREFIX.cbor"

[ "$(od -An -tx1 -v "$PREFIX.cbor" | tr -d ' \n')" = "$HEX" ] || { echo "hex/bin mismatch" >&2; exit 1; }

echo "network: $NETWORK (${NETARG[*]})"
echo "addr:    $ADDR"
echo "txid:    $(cardano-cli conway transaction txid --tx-file "$PREFIX.signed" | jq -r .txhash)"
echo "wrote:   $PREFIX.cbor ($(stat -c%s "$PREFIX.cbor") bytes), $PREFIX.hex, $PREFIX.signed"
