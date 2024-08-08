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

# Assist with KES rotation per environment
kes-rotate ENV CURRENT_KES_PERIOD:
  #!/usr/bin/env bash
  set -euo pipefail

  [ -n "${DEBUG:-}" ] && set -x

  if ! [[ "{{ENV}}" =~ preprod$|preview$|private$|sanchonet$|shelley-qa$ ]]; then
    echo "Error: only node environments for preprod, preview, private, sanchonet and shelley-qa are supported for kes-rotate recipe"
    exit 1
  fi

  # Set parameters for block producers
  BPs=("{{ENV}}1-bp-a-1" "{{ENV}}2-bp-b-1" "{{ENV}}3-bp-c-1")

  # Existing secrets are encrypted, and we'll want to leave it that way, so:

  for bp in "${BPs[@]}"; do
    # In our current deployments there is only one pool per group, so the group
    # can be extracted from the block producer name
    export POOL_GROUP="${bp%%-*}"
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
