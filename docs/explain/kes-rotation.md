# KES Rotation on Playground

## Just recipe KES rotation

KES rotation on playground is now easier with the following just recipe. After
this recipe has run, the KES rotated block producers need to be deployed to
receive the new credentials; see below.
```bash
just kes-rotate $ENV $CURRENT_KES_PERIOD
```

## Nix job KES rotation

Cardano-parts offers a nix job to do the bulk of the KES rotation work.  It
requires setting specific environment variables and running the nix job for
each block producer which needs KES rotation.

For our common playground networks, the just recipe above takes care of the
boilerplate set up for running this nix job for each block producer in a given
network.  However, if the nix job needs to be run manually for an edge case,
the set up details for running the job follow:
```bash
# Existing secrets are encrypted, and we'll want to leave it that way, so:
export USE_ENCRYPTION="true"
export USE_DECRYPTION="true"

# Provide extra output in case something goes wrong.
export DEBUG="true"

# If the node we are KES rotating is a pre-release deployment, we'll also
# need to set:
export UNSTABLE="true"

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

## Deploying rotated KES credentials

Deploy the new KES keys
```bash
# Deploy and ensure KES periods remaining of the cardano-node application
# metrics dashboard is updated.
just apply "$NODE_NAME"

# If all looks good, git add, commit and push the new encrypted secrets.
```

Repeat the steps above for each pool which requires KES rotation.
