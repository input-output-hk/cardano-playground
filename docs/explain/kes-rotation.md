# KES Rotation on Playground

Set the env variables to configure the KES rotation and call the nix rotation job
```bash
# Existing secrets are encrypted, and we'll want to leave it that way, so:
export USE_ENCRYPTION="true"
export USE_DECRYPTION="true"

# Provide extra output in case something goes wrong.
export DEBUG="true"

# If the node we are KES rotating is a pre-release deployment, we'll also
# need to set:
export UNSTABLE="true"
export UNSTABLE_LIB="true"

# Set the current KES period which can be obtained several ways, one of which
# is from the cardano-node application metrics dashboard.  This should be a
# positive numeric value, example: 574
export CURRENT_KES_PERIOD="<CHANGE_ME>"

# Set the pool name and secrets dir to rotate.
# The pool name is generally the node name hosting the block producer.
# The stake pool dir is generally the node group as a subdir of secrets/groups.
#
# An example would be:
#   export POOL_NAMES="preview1-bp-a-1"
#   export STAKE_POOL_DIR="secrets/groups/preview1"
#
export POOL_NAMES="$NODE_NAME"
export STAKE_POOL_DIR="secrets/groups/$GROUP_NAME"

# Run the nix KES rotation job
nix run .#job-rotate-kes-pools
```

Deploy the new KES keys
```bash
# Deploy and ensure KES periods remaining of the cardano-node application
# metrics dashboard is updated.
just apply "$NODE_NAME"

# If all looks good, git add, commit and push the new encrypted secrets.
```

Repeat the steps above for each pool which requires KES rotation.
