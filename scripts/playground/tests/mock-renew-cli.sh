#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_ROOT/calls"
arg() { local flag=$1; shift; while [ "$#" -gt 0 ]; do if [ "$1" = "$flag" ]; then printf '%s' "$2"; return; fi; shift; done; return 1; }
case "$*" in
  *'query tip'*) echo '{"syncProgress":"100.00","era":"'"${TEST_ERA:-Conway}"'","epoch":1490,"slot":100}' ;;
  *'query slot-number'*)
    if [ "$SCENARIO" = horizon-error ]; then echo 'Connection refused' >&2; exit 1; fi
    if [ "$SCENARIO" = horizon-exhausted ] || { [ "$SCENARIO" = leios ] && [ "$(grep -c 'query slot-number' "$TEST_ROOT/calls")" -le 3 ]; }; then
      echo 'Past horizon: PastHorizon' >&2; exit 1
    fi
    echo 43300 ;;
  *'query drep-state'*)
    case "$SCENARIO" in
      absent) echo '[]' ;;
      null-anchor) echo '[["drep-test",{"expiry":1399,"anchor":null}]]' ;;
      *) echo '[["drep-test",{"expiry":1399,"anchor":{"url":"https://example.org/drep.json","dataHash":"0123456789abcdef"}}]]' ;;
    esac ;;
  'key verification-key'*)
    dest=$(arg --verification-key-file "$@")
    if [ "$SCENARIO" = mismatch ]; then echo '{"type":"MockVerificationKey","cborHex":"00"}' > "$dest"
    else cp "$TEST_ROOT/key.vkey" "$dest"; fi ;;
  *'address build'*) echo addr_test_mock ;;
  *'query utxo'*)
    if [ "$SCENARIO" = no-funds ]; then echo '{}'
    else echo '{"abc#0":{"value":{"lovelace":5000000}}}'; fi ;;
  *'transaction sign'*)
    if [ "$SCENARIO" = interrupt ]; then sleep 30; fi
    if [ "$SCENARIO" = sign-failure ]; then echo 'Mock signing failure' >&2; exit 1; fi
    echo '{}' > "$(arg --out-file "$@")" ;;
  *'transaction txid'*) echo mock-txid ;;
  *'transaction submit'*) echo 'Must never submit' >&2; exit 99 ;;
  *'transaction build'*|*'update-certificate'*) echo '{}' > "$(arg --out-file "$@")" ;;
  *) echo "Unexpected mock command: $*" >&2; exit 1 ;;
esac
