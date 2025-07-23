#!/usr/bin/env bash
set -euo pipefail

[ -n "${DEBUG:-}" ] && set -x
[ -z "${ENV:-}" ] && { echo "ENV var must be set"; exit 1; }

if ! [ "${CC_INDEX+x}" = "x" ]; then
  echo "CC_INDEX var must be set: suggest empty (\"\") for the first CC, then 2, 3, 4, ..., for additional CC"
  exit 1
fi

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../bash-fns.sh"

DIR="cc-keys/cc${CC_INDEX}"
mkdir -p "$DIR"/{ca,roles}

# Create the root self-signed CA if it doesn't exist
if ! [ -f "$DIR/ca/ca.crt" ]; then
  openssl req -x509 \
    -newkey ed25519 \
    -nodes \
    -keyout "$DIR/ca/ca.key" \
    -out "$DIR/ca/ca.crt" \
    -days 3650 \
    -subj "/C=US/ST=Colorado/L=Longmont/O=Input Output Global/OU=CC$CC_INDEX - ${ENV^} Testnet/CN=www.iohk.io/emailAddress=security@iohk.io"

  # Initialize the CA serial number tracker; this is hex so SNs start at 4097
  touch "$DIR/ca/ca.srl"
  echo '1000' > "$DIR/ca/ca.srl"
else
  echo "Skipping CA root creation as it already exists"
fi

CREATE_ROLE() {
  ROLE="$1"
  INDEX="$2"

  if ! [ -f "$DIR/roles/$ROLE-$INDEX.crt" ]; then
    nu -c "print \$\"(ansi bg_green)Generating a role for $ROLE - $INDEX:(ansi reset)\""

    # Create a key for the role
    openssl genpkey \
      -algorithm ed25519 \
      -out "$DIR/roles/$ROLE-$INDEX.key"

    # Create a csr
    openssl req \
      -new \
      -key "$DIR/roles/$ROLE-$INDEX.key" \
      -out "$DIR/roles/$ROLE-$INDEX.csr" \
      -subj "/CN=${ROLE^} - $INDEX/OU=CC$CC_INDEX - ${ENV^} Testnet/O=Input Output Global/L=Longmont/ST=Colorado/C=US/emailAddress=security@iohk.io"

    # Two year default expiration
    openssl x509 \
      -req -in "$DIR/roles/$ROLE-$INDEX.csr" \
      -CA "$DIR/ca/ca.crt" \
      -CAkey "$DIR/ca/ca.key" \
      -CAserial "$DIR/ca/ca.srl" \
      -out "$DIR/roles/$ROLE-$INDEX.crt" \
      -days 730

    # Generate the cardano skey from openssl key pem
    orchestrator-cli from-pem "$DIR/roles/$ROLE-$INDEX.key" "$DIR/roles/$ROLE-$INDEX.skey"

    # Generate the cardano vkey from skey
    cardano-cli latest key verification-key --signing-key-file "$DIR/roles/$ROLE-$INDEX.skey" --verification-key-file "$DIR/roles/$ROLE-$INDEX.vkey"

    orchestrator-cli extract-pub-key-hash "$DIR/roles/$ROLE-$INDEX.crt" | tr -d '\n' > "$DIR/roles/$ROLE-$INDEX.crt.hash"

    # Review the cert info, pem fingerprint and cardano vkey
    echo
    echo "Cert info:"
    openssl x509 -in "$DIR/roles/$ROLE-$INDEX.crt" -text -noout

    echo
    echo "Cert public key hash:"
    cat "$DIR/roles/$ROLE-$INDEX.crt.hash"

    echo
    echo "Cert fingerprint:"
    openssl pkey -in "$DIR/roles/$ROLE-$INDEX.key" -noout -text

    echo
    echo "Role vkey:"
    cat "$DIR/roles/$ROLE-$INDEX.vkey"

    # Once the signed crt is available we not longer need the csr
    rm "$DIR/roles/$ROLE-$INDEX.csr"

    echo
  else
    echo "Skipping $ROLE - $INDEX as it already exists"
  fi
}

# Create expected roles for CC member internal governance structure
CREATE_ROLE membership 1
CREATE_ROLE membership 2
CREATE_ROLE membership 3
CREATE_ROLE deleg 1
CREATE_ROLE deleg 2
CREATE_ROLE deleg 3
CREATE_ROLE voter 1
CREATE_ROLE voter 2
CREATE_ROLE voter 3

# Create the orchestrator credentials if they don't already exist:
echo
if ! [ -f "$DIR/orchestrator.skey" ]; then
  echo "Creating orchestrator keys"
  cardano-cli address key-gen \
    --signing-key-file "$DIR/orchestrator.skey" \
    --verification-key-file "$DIR/orchestrator.vkey"

  # Generate the orchestrator address
  cardano-cli address build \
    --payment-verification-key-file "$DIR/orchestrator.vkey" \
    --out-file "$DIR/orchestrator.addr"
else
  echo "Skipping orchestrator keys as they already exist"
fi

ORCH_ADDR=$(cat "$DIR/orchestrator.addr")
ORCH_UTXO=$(cardano-cli latest query utxo --address "$ORCH_ADDR" | jq -r 'to_entries | .[] | select(.value.value | keys | length == 1)')

echo "Orchestrator address on $ENV for cc index \"$CC_INDEX\" is $ORCH_ADDR"

# Fund the orchestrator account if empty
if [ -z "$ORCH_UTXO" ]; then
  echo "Orchestrator address appears to have no UTXO -- attempting to fund 100 ADA"
  just fund-transfer "$ENV" "$ORCH_ADDR" 100000000
  ORCH_UTXO=$(cardano-cli latest query utxo --address "$ORCH_ADDR" | jq -r 'to_entries | .[] | select(.value.value | keys | length == 1)')
fi

echo "Orchestrator UTXO:"
echo "$ORCH_UTXO"

# Set up cold init state
echo
if ! [ -f "$DIR/init-cold/nft.addr" ]; then
  echo "Creating init cold"
  orchestrator-cli init-cold \
    --seed-input "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
    --testnet \
    --ca-cert "$DIR/ca/ca.crt" \
    --membership-cert "$DIR/roles/membership-1.crt" \
    --membership-cert "$DIR/roles/membership-2.crt" \
    --membership-cert "$DIR/roles/membership-3.crt" \
    --delegation-cert "$DIR/roles/deleg-1.crt" \
    --delegation-cert "$DIR/roles/deleg-2.crt" \
    --delegation-cert "$DIR/roles/deleg-3.crt" \
    -o "$DIR/init-cold"
else
  echo "Skipping init cold creation as it already exists"
fi

if ! [ -f "$DIR/init-cold/tx-mint-cc-nft.txbody" ]; then
  echo "Creating init cold transaction body"
  cardano-cli latest transaction build \
    --change-address "$ORCH_ADDR" \
    --tx-in "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
    --tx-in-collateral "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
    --tx-out "$(cat "$DIR/init-cold/nft.addr") + 5000000 + 1 $(cat "$DIR/init-cold/minting.plutus.hash").$(cat "$DIR/init-cold/nft-token-name")" \
    --tx-out-inline-datum-file "$DIR/init-cold/nft.datum.json" \
    --mint "1 $(cat "$DIR/init-cold/minting.plutus.hash").$(cat "$DIR/init-cold/nft-token-name")" \
    --mint-script-file "$DIR/init-cold/minting.plutus" \
    --mint-redeemer-file "$DIR/init-cold/mint.redeemer.json" \
    --out-file "$DIR/init-cold/tx-mint-cc-nft.txbody"
else
  echo "Skipping init cold creation transaction body as it already exists"
fi

if ! [ -f "$DIR/init-cold/tx-mint-cc-nft.txsigned" ]; then
  echo "Creating init cold signed transaction"
  cardano-cli latest transaction sign \
    --signing-key-file "$DIR/orchestrator.skey" \
    --tx-body-file "$DIR/init-cold/tx-mint-cc-nft.txbody" \
    --out-file "$DIR/init-cold/tx-mint-cc-nft.txsigned"

  submit "$DIR/init-cold/tx-mint-cc-nft.txsigned"
else
  echo "Skipping init cold signed transaction creation as it already exists"
fi

# Set up hot init state
echo
ORCH_UTXO=$(cardano-cli latest query utxo --address "$ORCH_ADDR" | jq -r 'to_entries | .[] | select(.value.value | keys | length == 1)')
echo "Orchestrator UTXO:"
echo "$ORCH_UTXO"

echo
if ! [ -f "$DIR/init-hot/nft.addr" ]; then
  echo "Creating init hot"
  orchestrator-cli init-hot \
    --seed-input "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
    --testnet \
    --cold-nft-policy-id "$(cat "$DIR/init-cold/minting.plutus.hash")" \
    --cold-nft-token-name "$(cat "$DIR/init-cold/nft-token-name")" \
    --voting-cert "$DIR/roles/voter-1.crt" \
    --voting-cert "$DIR/roles/voter-2.crt" \
    --voting-cert "$DIR/roles/voter-3.crt" \
    -o "$DIR/init-hot"
else
  echo "Skipping init hot creation as it already exists"
fi

if ! [ -f "$DIR/init-hot/tx-init-hot.txbody" ]; then
  echo "Creating init hot transaction body"
  cardano-cli latest transaction build \
    --change-address "$ORCH_ADDR" \
    --tx-in "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
    --tx-in-collateral "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
    --tx-out "$(cat "$DIR/init-hot/nft.addr") + 5000000 + 1 $(cat "$DIR/init-hot/minting.plutus.hash").$(cat "$DIR/init-hot/nft-token-name")" \
    --tx-out-inline-datum-file "$DIR/init-hot/nft.datum.json" \
    --mint "1 $(cat "$DIR/init-hot/minting.plutus.hash").$(cat "$DIR/init-hot/nft-token-name")" \
    --mint-script-file "$DIR/init-hot/minting.plutus" \
    --mint-redeemer-file "$DIR/init-hot/mint.redeemer.json" \
    --out-file "$DIR/init-hot/tx-init-hot.txbody"
else
  echo "Skipping init hot creation transaction body as it already exists"
fi

if ! [ -f "$DIR/init-hot/tx-init-hot.txsigned" ]; then
  echo "Creating init hot signed transaction"
  cardano-cli latest transaction sign \
    --signing-key-file "$DIR/orchestrator.skey" \
    --tx-body-file "$DIR/init-hot/tx-init-hot.txbody" \
    --out-file "$DIR/init-hot/tx-init-hot.txsigned"

  submit "$DIR/init-hot/tx-init-hot.txsigned"
else
  echo "Skipping init hot signed transaction creation as it already exists"
fi

# Authorize the hot credential
echo
cardano-cli latest query utxo --address "$(cat "$DIR/init-cold/nft.addr")" > "$DIR/cold-nft.utxo"
ORCH_UTXO=$(cardano-cli latest query utxo --address "$ORCH_ADDR" | jq -r 'to_entries | .[] | select(.value.value | keys | length == 1)')
echo "Orchestrator UTXO:"
echo "$ORCH_UTXO"

if ! [ -f "$DIR/authorize/authorizeHot.cert" ]; then
  echo "Creating hot credential authorization"
  orchestrator-cli authorize \
    --utxo-file "$DIR/cold-nft.utxo" \
    --cold-credential-script-file "$DIR/init-cold/credential.plutus" \
    --hot-credential-script-file "$DIR/init-hot/credential.plutus" \
    --out-dir "$DIR/authorize"
else
  echo "Skipping hot creation authorization as it already exists"
fi

# Using the tx-bundle approach throws an error which follows, so we'll stick with cardano-cli:
#
#   tx-bundle: DecoderFailure (LocalStateQuery HardForkBlock (': * ByronBlock (':
#   * (ShelleyBlock (TPraos StandardCrypto) (ShelleyEra StandardCrypto)) (': *
#   (ShelleyBlock (TPraos StandardCrypto) (AllegraEra StandardCrypto)) (': *
#   (ShelleyBlock (TPraos StandardCrypto) (MaryEra StandardCrypto)) (': *
#   (ShelleyBlock (TPraos StandardCrypto) (AlonzoEra StandardCrypto)) (': *
#   (ShelleyBlock (Praos StandardCrypto) (BabbageEra StandardCrypto)) (': *
#   (ShelleyBlock (Praos StandardCrypto) (ConwayEra StandardCrypto)) ('[]
#   *)))))))) Query (BlockQuery (HardForkBlock (': * ByronBlock (': *
#   (ShelleyBlock (TPraos StandardCrypto) (ShelleyEra StandardCrypto)) (': *
#   (ShelleyBlock (TPraos StandardCrypto) (AllegraEra StandardCrypto)) (': *
#   (ShelleyBlock (TPraos StandardCrypto) (MaryEra StandardCrypto)) (': *
#   (ShelleyBlock (TPraos StandardCrypto) (AlonzoEra StandardCrypto)) (': *
#   (ShelleyBlock (Praos StandardCrypto) (BabbageEra StandardCrypto)) (': *
#   (ShelleyBlock (Praos StandardCrypto) (ConwayEra StandardCrypto)) ('[]
#   *))))))))))) ServerAgency TokQuerying BlockQuery (QueryIfCurrent (QS (QS (QS
#   (QS (QS (QS (QZ (GetDRepState (fromList []))))))))))) (DeserialiseFailure 37
#   "Size mismatch when decoding Record RecD.\nExpected 4, but found 3.")
#
# if ! [ -f "$DIR/authorize/tx-authorize.txbundle" ]; then
#   echo "Creating hot credential authorization tx-bundle"
#   tx-bundle build \
#     --tx-in "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
#     --tx-in-collateral "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
#     --tx-in "$(cardano-cli query utxo --address "$(cat "$DIR/init-cold/nft.addr")" --output-json | jq -r 'keys[0]')" \
#     --tx-in-script-file "$DIR/init-cold/nft.plutus" \
#     --tx-in-inline-datum-present \
#     --tx-in-redeemer-file "$DIR/authorize/redeemer.json" \
#     --tx-out "$(cat "$DIR/authorize/value")" \
#     --tx-out-inline-datum-file "$DIR/authorize/datum.json" \
#     --required-signer-group-name delegation \
#     --required-signer-group-threshold 2 \
#     --required-signer-hash "$(orchestrator-cli extract-pub-key-hash "$DIR/roles/deleg-1.crt")" \
#     --required-signer-hash "$(orchestrator-cli extract-pub-key-hash "$DIR/roles/deleg-2.crt")" \
#     --required-signer-hash "$(orchestrator-cli extract-pub-key-hash "$DIR/roles/deleg-3.crt")" \
#     --certificate-file "$DIR/authorize/authorizeHot.cert" \
#     --certificate-script-file "$DIR/init-cold/credential.plutus" \
#     --certificate-redeemer-value {} \
#     --change-address "$(cat "$DIR/orchestrator.addr")" \
#     --out-file "$DIR/authorize/tx-authorize.txbundle"
# else
#   echo "Skipping hot creation authorization tx-bundle as it already exists"
# fi

if ! [ -f "$DIR/authorize/tx-authorize.txbody" ]; then
  echo "Creating hot credential authorization transaction body"
  cardano-cli latest transaction build \
    --tx-in "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
    --tx-in-collateral "$(jq -r '[., inputs][0].key' <<< "$ORCH_UTXO")" \
    --tx-in "$(cardano-cli query utxo --address "$(cat "$DIR/init-cold/nft.addr")" --output-json | jq -r 'keys[0]')" \
    --tx-in-script-file "$DIR/init-cold/nft.plutus" \
    --tx-in-inline-datum-present \
    --tx-in-redeemer-file "$DIR/authorize/redeemer.json" \
    --tx-out "$(cat "$DIR/authorize/value")" \
    --tx-out-inline-datum-file "$DIR/authorize/datum.json" \
    --required-signer-hash "$(orchestrator-cli extract-pub-key-hash "$DIR/roles/deleg-1.crt")" \
    --required-signer-hash "$(orchestrator-cli extract-pub-key-hash "$DIR/roles/deleg-2.crt")" \
    --required-signer-hash "$(orchestrator-cli extract-pub-key-hash "$DIR/roles/deleg-3.crt")" \
    --certificate-file "$DIR/authorize/authorizeHot.cert" \
    --certificate-script-file "$DIR/init-cold/credential.plutus" \
    --certificate-redeemer-value {} \
    --change-address "$(cat "$DIR/orchestrator.addr")" \
    --out-file "$DIR/authorize/tx-authorize.txbody"
else
  echo "Skipping hot creation authorization transaction body as it already exists"
fi

if ! [ -f "$DIR/authorize/tx-authorize.txsigned" ]; then
  echo "Creating hot credential authorization signed transaction"
  cardano-cli latest transaction sign \
    --signing-key-file "$DIR/orchestrator.skey" \
    --signing-key-file "$DIR/roles/deleg-1.skey" \
    --signing-key-file "$DIR/roles/deleg-2.skey" \
    --signing-key-file "$DIR/roles/deleg-3.skey" \
    --tx-body-file "$DIR/authorize/tx-authorize.txbody" \
    --out-file "$DIR/authorize/tx-authorize.txsigned"

  # Hot keys cannot be submitted until CC cold keys are in the current state or
  # in a proposed action, otherwise it will error out with:
  #
  #   Error: Error while submitting tx: ShelleyTxValidationError
  #   ShelleyBasedEraConway (ApplyTxError (ConwayCertsFailure (CertFailure
  #   (GovCertFailure (ConwayCommitteeIsUnknown (ScriptHashObj (ScriptHash
  #   "be4d67a5dd8de49543cc489aca920a377ea7a7e9855c8934d33e5765"))))) :| []))
  #
  # Instead, submit this signed transaction manually once the CC cold keys are
  # on chain or in a proposal.
  #
  # submit "$DIR/authorize/tx-authorize.txsigned"
else
  echo "Skipping hot credential authorization signed transaction as it already exists"
fi
