#!/usr/bin/env bash
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x

if [ "$#" -ne "6" ]; then
  echo "Six arguments are required:"
  echo "  $0 \$ENV \$CC_DIR \$ACTION_ID \$ACTION_IX \$VOTE \$ANCHOR_URL"
  echo
  echo "Where:"
  echo "  ENV should be 'preview' or 'preprod'"
  echo "  CC_DIR should be the cc-keys subdir for the environment, ex: 'cc' or 'cc2', etc"
  echo "  VOTE must be 'yes', 'no' or 'abstain'"
  echo "  ANCHOR_URL must the be CC voting rationale"
  exit 1
else
  ENV="$1"
  CC_DIR="$2"
  ACTION_ID="$3"
  ACTION_IX="$4"
  VOTE="$5"
  ANCHOR_URL="$6"
fi

export IPFS_GATEWAY_URI="https://ipfs.io"

ORCH_DIR="secrets/envs/$ENV/cc-keys/$CC_DIR"
INITHOT_DIR="$ORCH_DIR/init-hot"
SIGNER_DIR="$ORCH_DIR/roles"
ORCH_ADDR=$(just sops-decrypt-binary "$ORCH_DIR/orchestrator.addr")

# case "$VOTE" in
#   yes)
#     ANCHOR="https://raw.githubusercontent.com/carloslodelar/proposals/refs/heads/main/voteYES.jsonld"
#     ;;
#   no)
#     ANCHOR="https://raw.githubusercontent.com/carloslodelar/proposals/refs/heads/main/voteNO.jsonld"
#     ;;
#   abstain)
#     ANCHOR="https://raw.githubusercontent.com/carloslodelar/proposals/refs/heads/main/voteABSTAIN.jsonld"
#     ;;
#   *)
#     echo "Error: Invalid third argument. Please provide 'yes', 'no', or 'abstain'."
#     exit 1
#     ;;
# esac

# Hash the anchor data using cardano-cli.
# Note that using the `--text` option would result in an incorrect hash.
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
  --governance-action-index "$ACTION_IX" \
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
