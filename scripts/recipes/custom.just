# Include any repo customized justfile recipes in this file.
# Doing so will make diffing and patching the main repo Justfile easier.

# Build the prod cardano book
build-book-prod:
  #!/usr/bin/env bash
  set -euo pipefail

  ANSI_BG() {
    BG_COLOR="$1"; ANSI_STR="$2"; STR="$3"
    nu -c "print $\"(ansi $BG_COLOR)$ANSI_STR(ansi reset) $STR\""
  }

  [ -f flake/nixosModules/ips-DONT-COMMIT.nix ] && git reset -- flake/nixosModules/ips-DONT-COMMIT.nix &> /dev/null
  COMMIT=$(nix eval --raw --impure --expr 'let f = builtins.getFlake "git+file://${toString ./.}"; in (f.rev or f.dirtyRev)' 2> /dev/null)
  [ -f flake/nixosModules/ips-DONT-COMMIT.nix ] && git add --intent-to-add flake/nixosModules/ips-DONT-COMMIT.nix

  ln -rsf mdbook/book-prod.toml mdbook/book.toml
  if [[ "$COMMIT" =~ "dirty" ]]; then
    ANSI_BG "bg_light_red" "WARNING:" "The git state appears to be dirty: $COMMIT"
    ANSI_BG "bg_light_red" "WARNING:" "Generating the book with a \"PRODUCTION\" commit marker in the meantime."
    ANSI_BG "bg_light_red" "WARNING:" "Please obtain clean git state, except for ips-DONT-COMMIT file if in use, and try again."
    sed -ri "s|italic\".*</span>|italic\">PRODUCTION</span>|g" mdbook/README-book.md
    echo
  else
    ANSI_BG "bg_green" "STATUS:" "The git state appears to be clean: $COMMIT"
    echo
    read -p "Are all required book updates except for the commit stamp already generated and commited? [yY]? " -n 1 -r
    echo
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      ANSI_BG "bg_green" "STATUS:" "Generating the book with commit marker: $COMMIT..."
      sed -ri "s|italic\".*</span>|italic\">$COMMIT</span>|g" mdbook/README-book.md
    else
      ANSI_BG "bg_light_red" "WARNING:" "Generating the book with a \"PRODUCTION\" commit marker in the meantime."
      ANSI_BG "bg_light_red" "WARNING:" "Please obtain clean git state, except for ips-DONT-COMMIT file if in use, and try again."
      sed -ri "s|italic\".*</span>|italic\">PRODUCTION</span>|g" mdbook/README-book.md
    fi
    echo
  fi

  mdbook build mdbook/
  echo
  ANSI_BG "bg_light_purple" "REMINDER:" "Ensure node version statement and link for each environment are up to date."

# Build the staging cardano book
build-book-staging:
  #!/usr/bin/env bash
  set -euo pipefail

  ANSI_BG() {
    BG_COLOR="$1"; ANSI_STR="$2"; STR="$3"
    nu -c "print $\"(ansi $BG_COLOR)$ANSI_STR(ansi reset) $STR\""
  }

  [ -f flake/nixosModules/ips-DONT-COMMIT.nix ] && git reset -- flake/nixosModules/ips-DONT-COMMIT.nix &> /dev/null
  COMMIT=$(nix eval --raw --impure --expr 'let f = builtins.getFlake "git+file://${toString ./.}"; in (f.rev or f.dirtyRev)' 2> /dev/null)
  [ -f flake/nixosModules/ips-DONT-COMMIT.nix ] && git add --intent-to-add flake/nixosModules/ips-DONT-COMMIT.nix

  ln -rsf mdbook/book-staging.toml mdbook/book.toml
  sed -ri "s|italic\".*</span>|italic\">STAGING:$COMMIT</span>|g" mdbook/README-book.md

  mdbook build mdbook/
  echo
  ANSI_BG "bg_light_purple" "REMINDER:" "Ensure node version statement and link for each environment are up to date."

# Transfer funds from an environment rich key to another address
fund-transfer ENV SEND_ADDR LOVELACE UTXO="auto":
  #!/usr/bin/env bash
  set -euo pipefail
  {{checkEnvWithoutOverride}}

  if ! [[ "$ENV" =~ ^preprod$|^preview$|^demo$ ]]; then
    echo "Error: only node environments for preprod and preview and demo are supported"
    exit 1
  fi

  just set-default-cardano-env "$ENV" "$MAGIC" "$PPID"
  export CARDANO_NODE_NETWORK_ID="$MAGIC"
  export TESTNET_MAGIC="$MAGIC"
  echo

  [ -n "${DEBUG:-}" ] && set -x

  TS=$(date -u +%y-%m-%d_%H-%M-%S)
  BASENAME="tx-fund-transfer-$ENV-$TS"
  SEND_ADDR="{{SEND_ADDR}}"
  LOVELACE="{{LOVELACE}}"
  UTXO="{{UTXO}}"

  TIP=$(just query-tip "$ENV")
  if [ "$(jq -re .syncProgress <<< "$TIP")" != "100.00" ]; then
    echo "Please wait until the local tip of environment $ENV is 100.00 before transferring funds"
    exit 1
  fi

  if ! [[ "$LOVELACE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: LOVELACE given does not appear to be a number"
    exit 1
  fi

  if [ "${USE_SHELL_BINS:-}" = "true" ]; then
    CARDANO_CLI="cardano-cli"
  elif [ -n "${UNSTABLE:-}" ] && [ "${UNSTABLE:-}" != "true" ]; then
    CARDANO_CLI="cardano-cli"
  elif [ "${UNSTABLE:-}" = "true" ]; then
    CARDANO_CLI="cardano-cli-ng"
  elif [[ "$ENV" =~ ^preprod$|^preview$ ]]; then
    CARDANO_CLI="cardano-cli"
  fi

  PROMPT() {
    echo
    read -p "Does this look correct [yY]? " -n 1 -r
    echo
    if ! [[ $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborting the fund transfer."
      exit 1
    fi
    echo
  }

  echo "For environment $ENV, the SEND_TO address of $SEND_ADDR contains the following UTxOs:"
  eval "$CARDANO_CLI" latest query utxo --address "$SEND_ADDR" | jq
  PROMPT

  CHANGE_ADDR=$(just sops-decrypt-binary secrets/envs/$ENV/utxo-keys/rich-utxo.addr)
  echo "For environment $ENV, the rich key address of $CHANGE_ADDR contains the following lovelace only UTxOs:"
  eval "$CARDANO_CLI" latest query utxo --address "$CHANGE_ADDR" | jq 'to_entries | map(select(.value.value | length == 1)) | sort_by(.value.value.lovelace) | from_entries'
  PROMPT

  if [ "$UTXO" = "auto" ]; then
    MIN_UTXO_VALUE=$((LOVELACE + 5000000))
    echo "The auto-selected UTXO with a min value of the requested transfer, $LOVELACE lovelace, plus 5 ADA and no native tokens is:"
    SELECTED_UTXO=$(
      eval "$CARDANO_CLI" query utxo \
        --address "$CHANGE_ADDR" \
        --testnet-magic "$TESTNET_MAGIC" \
        --output-json \
      | jq -e -r --arg minUtxoValue "$MIN_UTXO_VALUE" 'to_entries
        |
          [
            sort_by(.value.value.lovelace)[]
              | select(.value.value.lovelace >= ($minUtxoValue | tonumber) and (.value.value | length) == 1)
              | {"txin": .key, "address": .value.address, "amount": .value.value.lovelace}
          ]
        [0]'
    )
  else
    echo "The provided UTXO has an ID and value of:"
    SELECTED_UTXO=$(
      eval "$CARDANO_CLI" query utxo \
        --address "$CHANGE_ADDR" \
        --testnet-magic "$TESTNET_MAGIC" \
        --output-json \
      | jq -e -r --arg selectedUtxo "$UTXO" 'to_entries[]
        |
          select(.key == $selectedUtxo)
            | {"txin": .key, "address": .value.address, "amount": .value.value.lovelace}'
    )
  fi

  TXIN=$(jq -r .txin <<< "$SELECTED_UTXO")
  TXIN_VALUE=$(jq -r .amount <<< "$SELECTED_UTXO")
  echo "  UTXO: $TXIN"
  echo "  Value: $TXIN_VALUE"
  echo
  echo "Assembling transaction with details of:"
  echo "  Send to address: $SEND_ADDR"
  echo "  From address: $CHANGE_ADDR"
  echo "  Send amount: $LOVELACE lovelace"
  echo "  Funding UTxO: $TXIN"
  echo "  Funding UTxO value: $TXIN_VALUE lovelace"
  PROMPT

  eval "$CARDANO_CLI" latest transaction build \
    --tx-in "$TXIN" \
    --tx-out "$SEND_ADDR+$LOVELACE" \
    --change-address "$CHANGE_ADDR" \
    --testnet-magic "$TESTNET_MAGIC" \
    --out-file "$BASENAME.raw"

  eval "$CARDANO_CLI" latest transaction sign \
    --tx-body-file "$BASENAME.raw" \
    --signing-key-file <(just sops-decrypt-binary secrets/envs/${ENV}/utxo-keys/rich-utxo.skey) \
    --testnet-magic "$TESTNET_MAGIC" \
    --out-file "$BASENAME.signed"

  echo
  echo "The transaction has been prepared and signed:"
  eval "$CARDANO_CLI" debug transaction view --tx-file "$BASENAME.signed"
  echo
  echo "If you answer affirmative to the next prompt this transaction will be submitted to the network!"
  PROMPT

  echo "Submitting the transaction to the network:"
  eval "$CARDANO_CLI" latest transaction submit --tx-file "$BASENAME.signed"
  echo

  TXID=$(eval "$CARDANO_CLI" latest transaction txid --tx-file "$BASENAME.signed")
  EXISTS="true"

  while [ "$EXISTS" = "true" ]; do
    EXISTS=$(eval "$CARDANO_CLI" latest query tx-mempool tx-exists $TXID | jq -r .exists)
    if [ "$EXISTS" = "true" ]; then
      echo "The transaction still exists in the mempool, sleeping 5s: $TXID"
    else
      echo "The transaction has been removed from the mempool."
    fi
    sleep 5
  done
  echo
  echo "Fund transfer completed."

# Assist with KES rotation per environment
kes-rotate ENV CURRENT_KES_PERIOD:
  #!/usr/bin/env bash
  set -euo pipefail

  [ -n "${DEBUG:-}" ] && set -x

  if ! [[ "{{ENV}}" =~ preprod$|preview$ ]]; then
    echo "Error: only node environments for preprod and preview are supported for kes-rotate recipe"
    exit 1
  fi

  # Set parameters for block producers
  BPs=("{{ENV}}1-bp-a-1" "{{ENV}}2-bp-b-1" "{{ENV}}3-bp-c-1")

  # Existing secrets are encrypted, and we'll want to leave it that way, so:

  for bp in "${BPs[@]}"; do
    # In our current deployments there is only one pool per group, so the group
    # can be extracted from the block producer name
    [[ "$bp" =~ ^([-_a-zA-Z]+[0-9]+).*$ ]]
    export POOL_GROUP="${BASH_REMATCH[1]}"
    # The plural of the `POOL_NAMES` variable reflects the legacy deployment
    # style and rare use cases of placing multiple block producers per group.
    # We aren't doing that with the common networks, so only one block
    # producer is assigned per group.
    export POOL_NAMES="$bp"
    export STAKE_POOL_DIR="secrets/groups/$POOL_GROUP"

    # Set env variables for the nix kes rotation job
    export CURRENT_KES_PERIOD="{{CURRENT_KES_PERIOD}}"
    export USE_ENCRYPTION="true"
    export USE_DECRYPTION="true"
    if [[ "{{ENV}}" =~ preprod$|preview$ ]]; then
      export UNSTABLE=false
    else
      export UNSTABLE=true
    fi

    # Run the nix KES rotation job
    nix run .#job-rotate-kes-pools
  done
