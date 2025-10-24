#!/usr/bin/env bash
# shellcheck disable=SC2031
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

[ -z "${RATIONALE_FILE:-}" ] && { echo "RATIONALE_FILE var must be set"; exit 1; }

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# See a example/template rationale files at CF CIP-136:
# https://github.com/cardano-foundation/CIPs/tree/master/CIP-0136/examples

cardano-signer sign --cip100 \
  --data-file "$RATIONALE_FILE" \
  --secret-key <(just sops-decrypt-binary "$SCRIPT_DIR/../../secrets/envs/$ENV/cc-keys/rationale-signer.json" | jq -r '.output.skey') \
  --author-name "IOE Node SRE for ${ENV^}" \
  --replace \
  --out-file "$RATIONALE_FILE.signed"

cardano-signer verify --cip100 \
  --data-file "$RATIONALE_FILE.signed" \
  --json \
  | jq .
