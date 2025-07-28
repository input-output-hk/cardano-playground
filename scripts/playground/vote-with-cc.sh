#!/usr/bin/env bash
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x

[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }
[ -z "${CC_DIR:-}" ] && { echo "CC_DIR var must be set, example: 'cc' or 'cc2', ..."; exit 1; }
[ -z "${ACTION_ID:-}" ] && { echo "ACTION_ID var must be set"; exit 1; }
[ -z "${ACTION_IDX:-}" ] && { echo "ACTION_IDX var must be set"; exit 1; }
[ -z "${VOTE:-}" ] && { echo "VOTE var must be set as 'yes', 'no' or 'abstain'"; exit 1; }
[ -z "${ANCHOR_URL:-}" ] && { echo "ANCHOR_URL var must be set to the CC voting rationale, preferably as 'ipfs://...' using CIDv0"; exit 1; }

export IPFS_GATEWAY_URI="https://ipfs.io"

ORCH_DIR="secrets/envs/$ENV/cc-keys/$CC_DIR"
INITHOT_DIR="$ORCH_DIR/init-hot"
SIGNER_DIR="$ORCH_DIR/roles"
ORCH_ADDR=$(just sops-decrypt-binary "$ORCH_DIR/orchestrator.addr")

# For signing voting rationale, see scripts/playground/cc-sign-rationale.sh
cardano-cli hash anchor-data \
  --url "$ANCHOR_URL" --out-file anchor.hash

cardano-cli conway query utxo \
  --address "$(just sops-decrypt-binary "$INITHOT_DIR/nft.addr")" \
  --output-json \
    | jq '
      [
        to_entries
          | .[]
          | select(.value.value["'"$(cat <(just sops-decrypt-binary "$INITHOT_DIR/minting.plutus.hash"))"'"]["'"$(cat <(just sops-decrypt-binary "$INITHOT_DIR/nft-token-name"))"'"])
      ] | from_entries' \
    > hot-nft.utxo

orchestrator-cli vote \
  --utxo-file hot-nft.utxo \
  --hot-credential-script-file <(just sops-decrypt-binary "$INITHOT_DIR/credential.plutus") \
  --governance-action-tx-id "$ACTION_ID" \
  --governance-action-index "$ACTION_IDX" \
  --"$VOTE" \
  --metadata-url "$ANCHOR_URL" \
  --metadata-hash "$(cat anchor.hash)" \
  --out-dir vote

cardano-cli conway transaction build \
  --tx-in "$(cardano-cli conway query utxo --address "$ORCH_ADDR" --output-json | jq -r 'keys[0]')" \
  --tx-in-collateral "$(cardano-cli conway query utxo --address "$ORCH_ADDR" --output-json | jq -r 'keys[0]')" \
  --tx-in "$(jq -r 'keys[0]' hot-nft.utxo)" \
  --tx-in-script-file <(just sops-decrypt-binary "$INITHOT_DIR/nft.plutus") \
  --tx-in-inline-datum-present \
  --tx-in-redeemer-file "vote/redeemer.json" \
  --tx-out "$(cat vote/value)" \
  --tx-out-inline-datum-file "vote/datum.json" \
  --required-signer-hash "$(orchestrator-cli extract-pub-key-hash <(just sops-decrypt-binary "$SIGNER_DIR/voter-1.crt"))" \
  --required-signer-hash "$(orchestrator-cli extract-pub-key-hash <(just sops-decrypt-binary "$SIGNER_DIR/voter-2.crt"))" \
  --required-signer-hash "$(orchestrator-cli extract-pub-key-hash <(just sops-decrypt-binary "$SIGNER_DIR/voter-3.crt"))" \
  --vote-file "vote/vote" \
  --vote-script-file <(just sops-decrypt-binary "$INITHOT_DIR/credential.plutus") \
  --vote-redeemer-value {} \
  --change-address "$ORCH_ADDR" \
  --out-file body.json

cardano-cli conway transaction witness \
  --tx-body-file body.json \
  --signing-key-file <(just sops-decrypt-binary "${SIGNER_DIR}/voter-1.skey") \
  --out-file voter1.witness

cardano-cli conway transaction witness \
  --tx-body-file body.json \
  --signing-key-file <(just sops-decrypt-binary "${SIGNER_DIR}/voter-2.skey") \
  --out-file voter2.witness

cardano-cli conway transaction witness \
  --tx-body-file body.json \
  --signing-key-file <(just sops-decrypt-binary "${SIGNER_DIR}/voter-3.skey") \
  --out-file voter3.witness

cardano-cli conway transaction witness \
  --tx-body-file body.json \
  --signing-key-file <(just sops-decrypt-binary "${ORCH_DIR}/orchestrator.skey") \
  --out-file orchestrator.witness

cardano-cli conway transaction assemble \
  --tx-body-file body.json \
  --witness-file voter1.witness \
  --witness-file voter2.witness \
  --witness-file voter3.witness \
  --witness-file orchestrator.witness \
  --out-file vote-tx.signed

echo
echo "The debug view of the transaction body is:"
cardano-cli debug transaction view --tx-file vote-tx.signed
echo
echo
echo "This transaction may be submitted to the network with the following command:"
echo "cardano-cli conway transaction submit --tx-file vote-tx.signed"
