# Include any repo customized justfile recipes in this file.
# Doing so will make diffing and patching the main repo Justfile easier.

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
