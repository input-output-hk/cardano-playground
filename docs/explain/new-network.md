# Creating a new network in playground

First, set parameters for nix helper jobs:
```bash
# Because we set UNSTABLE=true and UNSTABLE_LIB=true, this indicates
# we wish to build a network for pre-release, which will use iohk-nix-ng
# cardano-parts flake pin to determine configuration.  It also implies
# we should use the `-ng` (next generation) variant of cardano commands
# in the devShell.
#
# USE_ENCRYPTION and USE_DECRYPTION are false as we'll apply encryption
# as a secondary step before committing to the repo so that we don't
# make the initial spin up more complicated than necessary.
export ENV=private
export DEBUG=true
export UNSTABLE=true
export UNSTABLE_LIB=true
export TESTNET_MAGIC=5
export CARDANO_NODE_NETWORK_ID=5
export DATA_DIR=workbench/custom/rundir
export CARDANO_NODE_SOCKET_PATH="$DATA_DIR/node.socket"
export CURRENT_KES_PERIOD=0
export KEY_DIR="workbench/custom/envs/$ENV"
export PAYMENT_KEY="$KEY_DIR/utxo-keys/rich-utxo"
export POOL_RELAY="$ENV-node.play.dev.cardano.org"
export POOL_RELAY_PORT="3001"
export NUM_GENESIS_KEYS="3"
export USE_ENCRYPTION=false
export USE_DECRYPTION=false
export USE_NODE_CONFIG_BP=false
```

Create the basic genesis and node configurations
```bash
# The time given can be in the past, so a convienent 00:00Z time can be used.
SECURITY_PARAM=36 \
START_TIME="2024-05-16T00:00:00Z" \
nix run .#job-gen-custom-node-config
```

Create stake pools with each belonging to a seperate pool group
```bash
# In the cardano-playground Justfile, the start-demo recipe
# creates multiple pools under a single group.  This approach
# is ok for the demo, but when creating independent pool groups
# to be deployed for a full network, it's easiest to create one
# pool per group.  This also makes secrets handling easier.
POOL_NAMES="${ENV}1-bp-a-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}1 \
nix run .#job-create-stake-pool-keys

POOL_NAMES="${ENV}2-bp-b-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}2 \
nix run .#job-create-stake-pool-keys

POOL_NAMES="${ENV}3-bp-c-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}3 \
nix run .#job-create-stake-pool-keys
```

Create the bulk credentials file of genesis delegates and pools
```bash
# Combine BFT creds and pool creds from all three pools into one
# bft+pools bulk credentials file for ease of initial spin up:
(
  for i in $(fd bulk.creds.*.json workbench/); do
    jq .[] < $i;
  done
) | jq -s > workbench/custom/rundir/bulk.creds.all.json
```

Update, prettify, customize genesis and node config
```bash
# For cardano-parts -> cardano-playground workflow:
# Now would be a good time to make customizations to genesis
# and config prior to the next steps, this would include:
# 1) Update iohk-nix with the newly created genesis and configs
# 2) jq format any files to make them pretty (create-cardano,
#    for example, will create a minified byron-genesis by default)
# 3) Make any other customization, for example, to conway genesis
# 4) Calculate new genesis hashes with cardano-cli and update
#    them in iohk-nix
# 5) Update the iohk-nix[-ng] pins in cardano-parts
# 6) Update the cardano-parts pin in cardano-playground
#
# Generate new config:
nix run .#job-gen-env-config
```

Check updated, prettified, customized config is correct
and place it in the data dir
```bash
# Depending what environment you are configuring you may want
# to choose from environment or environments-pre in the result dir
# and environment or environment-pre in the docs dir
cp result/environments[-pre]/config/$ENV/* docs/environments[-pre]/$ENV/
chmod +w -R docs/environments[-pre]/$ENV/

# As a sanity check, compare the sanitized config against the
# the `create-cardano` config created during the
# .#job-gen-custom-node-config nix job:
diff -Naru "$DATA_DIR" docs/environments[-pre]/$ENV/

# Reconcile unexpected differences, if any, and copy over sanitized config
cp docs/environments[-pre]/$ENV/*genesis*.json "$DATA_DIR"
cp docs/environments[-pre]/$ENV/config-bp.json "$DATA_DIR"/node-config.json
```

Set your machine clock to the appropriate runtime
```bash
# Set datetime to just before the start time
sudo systemctl stop systemd-timesyncd.service
sudo date -u -s '2024-05-15 23:59:00Z'
```

Start node, move funds from byron to shelley address and register pools.

Note: pools will be created with a default pledge of 10M ADA which also matches
the default faucet pool delegation configured by setup-delegation-accounts.py
during faucet setup.  To choose differently, set the POOL_PLEDGE env var in
lovelace.  Additional configuration options for setting pool metadata url, port
and more are available.  See the cardano-parts repo's `flakeModules/jobs.nix`
file for details.
```bash
# Start node for the first time
cardano-node-ng run \
  --config "$DATA_DIR"/node-config.json \
  --database-path "$DATA_DIR"/db \
  --topology "$DATA_DIR"/topology.json \
  +RTS -N2 -A16m -qg -qb -M3584.000000M -RTS \
  --socket-path "$DATA_DIR"/node.socket \
  --bulk-credentials-file "$DATA_DIR"/bulk.creds.all.json \
  | tee -a "$DATA_DIR"/node.log

# In another window with all the above env vars exported:
echo "Moving genesis utxo..."
BYRON_SIGNING_KEY="$KEY_DIR"/utxo-keys/shelley.000.skey \
ERA_CMD="alonzo" \
nix run .#job-move-genesis-utxo
sleep 30

# Note: This defaults to 10M ADA pool pledge; see note above
echo "Registering stake pools..."
POOL_NAMES="${ENV}1-bp-a-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}1 \
ERA_CMD="alonzo" \
nix run .#job-register-stake-pools
sleep 30

POOL_NAMES="${ENV}1-bp-a-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}1 \
ERA_CMD="alonzo" \
nix run .#job-delegate-rewards-stake-key
sleep 30

POOL_NAMES="${ENV}2-bp-b-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}2 \
ERA_CMD="alonzo" \
nix run .#job-register-stake-pools
sleep 30

POOL_NAMES="${ENV}2-bp-b-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}2 \
ERA_CMD="alonzo" \
nix run .#job-delegate-rewards-stake-key
sleep 30

POOL_NAMES="${ENV}3-bp-c-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}3 \
ERA_CMD="alonzo" \
nix run .#job-register-stake-pools
sleep 30

POOL_NAMES="${ENV}3-bp-c-1" \
STAKE_POOL_DIR=workbench/custom/groups/${ENV}3 \
ERA_CMD="alonzo" \
nix run .#job-delegate-rewards-stake-key
sleep 30
```

Stop node after immutable block size is increasing
```bash
# After creating the pools, wait until the immutable
# file state size starts to increment before stopping
# the node, otherwise some txs can being lost.
❯ ls -la $DATA_DIR/db/immutable
drwxr-xr-x 2 jlotoski users    5 May 15 18:59 .
drwxr-xr-x 5 jlotoski users    7 May 15 18:59 ..
-rw-r--r-- 1 jlotoski users 1969 May 15 19:12 00000.chunk
-rw-r--r-- 1 jlotoski users   93 May 15 19:12 00000.primary
-rw-r--r-- 1 jlotoski users  112 May 15 19:12 00000.secondary

# Look at the tip and protocol params right before stopping node
cardano-cli-ng query tip
cardano-cli-ng query protocol-parameters | jq .protocolVersion
{
    "block": 40,
    "epoch": 0,
    "era": "Alonzo",
    "hash": "183df29929039d0225c266e943d50416f948d12cdf6755af29b8a9bccb1539e6",
    "slot": 800,
    "slotInEpoch": 800,
    "slotsToEpochEnd": 6400,
    "syncProgress": "100.00"
}
  "protocolVersion": {
    "major": 6,
    "minor": 0
  },

# Stop the node and backup state
cp -a "$DATA_DIR"/db "$DATA_DIR"/db-alonzo-epoch-0-prot-6-slot-800
```

Synthesize blocks until the end of the epoch
```bash
# Backup protocolMagicId file as we need to delete it and
# replace it before and after each synthesis
cp "$DATA_DIR"/db/protocolMagicId "$DATA_DIR"/

# If it exists, delete the gsm directory which may contain a `CaughtUpMarker`
# file.  If this directory is present, it will prevent db-synthesizer from
# working.
rm -rf "$DATA_DIR"/db/gsm

# Prep for synthesis
rm "$DATA_DIR"/db/{clean,lock,protocolMagicId}

# Use the "slotsToEpochEnd" from the last tip query
# to synthesize blocks to epoch boundary
db-synthesizer-ng \
  --config "$DATA_DIR"/node-config.json \
  --db "$DATA_DIR"/db \
  --bulk-credentials-file "$DATA_DIR/bulk.creds.all.json" \
  -a \
  -s 6400
cp "$DATA_DIR"/protocolMagicId "$DATA_DIR"/db/
```

Match local time to the time of the tip of the chain
```bash
# Set datetime to the required time
# Start Target: 2024-05-16T02:00:00Z epoch 1
sudo systemctl stop systemd-timesyncd.service
sudo date -u -s '2024-05-16T01:59:00Z'
```

Start node, verify pools and hard fork to babbage
```bash
cardano-node-ng run \
  --config "$DATA_DIR"/node-config.json \
  --database-path "$DATA_DIR"/db \
  --topology "$DATA_DIR"/topology.json \
  +RTS -N2 -A16m -qg -qb -M3584.000000M -RTS \
  --socket-path "$DATA_DIR"/node.socket \
  --bulk-credentials-file "$DATA_DIR"/bulk.creds.all.json \
  | tee -a "$DATA_DIR"/node.log

# In the new epoch, confirm pools and distribution display
cardano-cli-ng query stake-pools
pool185cesaua779sprx3f4np4dkalkvqqf6nuaklzt69keruvs6p2mw
pool132gzvkkh67u2aux5p6a2axrdp9hqt2wnrhc2rvdp6mq9qp22kf7
pool1uwh7vt04tx0gt9hh9qexdjgyncsnd3vr4nc524lxtj8qwrfuslt

cardano-cli-ng query stake-distribution
                           PoolId                                 Stake frac
------------------------------------------------------------------------------
pool185cesaua779sprx3f4np4dkalkvqqf6nuaklzt69keruvs6p2mw   3.332e-5
pool132gzvkkh67u2aux5p6a2axrdp9hqt2wnrhc2rvdp6mq9qp22kf7   3.332e-5
pool1uwh7vt04tx0gt9hh9qexdjgyncsnd3vr4nc524lxtj8qwrfuslt   3.332e-5

# While node is running, now in epoch 1, HF to babbage
MAJOR_VERSION=7 \
  ERA_CMD="alonzo" \
  nix run .#job-update-proposal-hard-fork

# Wait for several additional blocks to be synthesized, and
# verify the latest immutable file size is increasing, then
# record the tip info and stop node.
{
    "block": 373,
    "epoch": 1,
    "era": "Alonzo",
    "hash": "5159dee83c31220c02eac671c38580bb525f8638e6e34e8373182537c793e4d6",
    "slot": 7460,
    "slotInEpoch": 260,
    "slotsToEpochEnd": 6940,
    "syncProgress": "100.00"
}
{
  "major": 6,
  "minor": 0
}
```

Synthesize blocks until the end of the epoch
```bash
# Use the "slotsToEpochEnd" from the last tip query
# to synthesize blocks to epoch boundary
rm "$DATA_DIR"/db/{clean,lock,protocolMagicId}
db-synthesizer-ng \
  --config "$DATA_DIR"/node-config.json \
  --db "$DATA_DIR"/db \
  --bulk-credentials-file "$DATA_DIR/bulk.creds.all.json" \
  -a \
  -s 6940
cp "$DATA_DIR"/protocolMagicId "$DATA_DIR"/db/
```

Match local time to the time of the tip of the chain
```bash
# Set datetime to the required time
# Target: 2024-05-16T04:00:00Z epoch 2
sudo systemctl stop systemd-timesyncd.service
sudo date -u -s '2024-05-16T03:59:00Z'
```

Start node, verify babbage hard fork and hard fork to babbage inter-era
```bash
# Restart node, watch the HF into protocol 7.0 as it goes to epoch 2,
# then submit the next HF proposal to protocol 8.0:
cardano-node-ng run \
  --config "$DATA_DIR"/node-config.json \
  --database-path "$DATA_DIR"/db \
  --topology "$DATA_DIR"/topology.json \
  +RTS -N2 -A16m -qg -qb -M3584.000000M -RTS \
  --socket-path "$DATA_DIR"/node.socket \
  --bulk-credentials-file "$DATA_DIR"/bulk.creds.all.json \
  | tee -a "$DATA_DIR"/node.log

MAJOR_VERSION=8 \
  ERA_CMD="babbage" \
  nix run .#job-update-proposal-hard-fork

# Wait for several additional blocks to be synthesized, and
# verify the latest immutable file size is increasing, then
# record the tip info and stop node.
{
    "block": 736,
    "epoch": 2,
    "era": "Babbage",
    "hash": "6a27ccd9104a4b04a8d9d0a47853f349dcc5d7bb5e44643f5b319348b0dce45e",
    "slot": 14785,
    "slotInEpoch": 385,
    "slotsToEpochEnd": 6815,
    "syncProgress": "100.00"
}
{
  "major": 7,
  "minor": 0
}
```

Synthesize blocks until the end of the epoch
```bash
# Use the "slotsToEpochEnd" from the last tip query
# to synthesize blocks to epoch boundary
rm "$DATA_DIR"/db/{clean,lock,protocolMagicId}
db-synthesizer-ng \
  --config "$DATA_DIR"/node-config.json \
  --db "$DATA_DIR"/db \
  --bulk-credentials-file "$DATA_DIR/bulk.creds.all.json" \
  -a \
  -s 6815
cp "$DATA_DIR"/protocolMagicId "$DATA_DIR"/db/
```

Match local time to the time of the tip of the chain
```bash
# Set datetime to the required time
# Start Target: 2024-05-16T06:00:00Z epoch 3
sudo systemctl stop systemd-timesyncd.service
sudo date -u -s '2024-05-16T05:59:00Z'
```

Start node, verify babbage inter-era hard fork and hard fork to conway
```bash
# Restart node, watch the HF into protocol 8.0 as it goes to epoch 3,
# then submit the next HF proposal to protocol 9.0:
cardano-node-ng run \
  --config "$DATA_DIR"/node-config.json \
  --database-path "$DATA_DIR"/db \
  --topology "$DATA_DIR"/topology.json \
  +RTS -N2 -A16m -qg -qb -M3584.000000M -RTS \
  --socket-path "$DATA_DIR"/node.socket \
  --bulk-credentials-file "$DATA_DIR"/bulk.creds.all.json \
  | tee -a "$DATA_DIR"/node.log

MAJOR_VERSION=9 \
  ERA_CMD="babbage" \
  nix run .#job-update-proposal-hard-fork

# Wait for several additional blocks to be synthesized, and
# verify the latest immutable file size is increasing, then
# record the tip info and stop node.
{
    "block": 1087,
    "epoch": 3,
    "era": "Babbage",
    "hash": "4ba999a1755df7a7045d5c6a90c43398fc0fc4701814b88580f9181deee983db",
    "slot": 21742,
    "slotInEpoch": 142,
    "slotsToEpochEnd": 7058,
    "syncProgress": "100.00"
}
{
  "major": 8,
  "minor": 0
}

# Backup state:
cp -a "$DATA_DIR"/db \
  "$DATA_DIR"/db-babbage-epoch-3-prot-8-slot-21742-hf-submitted
```

Synthesize blocks until the end of the epoch
```bash
# Use the "slotsToEpochEnd" from the last tip query
# to synthesize blocks to epoch boundary
rm "$DATA_DIR"/db/{clean,lock,protocolMagicId}
db-synthesizer-ng \
  --config "$DATA_DIR"/node-config.json \
  --db "$DATA_DIR"/db \
  --bulk-credentials-file "$DATA_DIR/bulk.creds.all.json" \
  -a \
  -s 7058
cp "$DATA_DIR"/protocolMagicId "$DATA_DIR"/db/
```

Match local time to the time of the tip of the chain
```bash
# Set datetime to the required time
# Start Target: 2024-05-16T08:00:00Z epoch 4
sudo systemctl stop systemd-timesyncd.service
sudo date -u -s '2024-05-16T07:59:00Z'
```

Start node and verify conway hard fork
```bash
# Restart node, watch the HF into protocol 9.0 as it goes to epoch 4
cardano-node-ng run \
  --config "$DATA_DIR"/node-config.json \
  --database-path "$DATA_DIR"/db \
  --topology "$DATA_DIR"/topology.json \
  +RTS -N2 -A16m -qg -qb -M3584.000000M -RTS \
  --socket-path "$DATA_DIR"/node.socket \
  --bulk-credentials-file "$DATA_DIR"/bulk.creds.all.json \
  | tee -a "$DATA_DIR"/node.log

# Wait for several additional blocks to be synthesized, and
# verify the latest immutable file size is increasing, then
# record the tip info and stop node.
{
    "block": 1462,
    "epoch": 4,
    "era": "Conway",
    "hash": "58e76f76c6f63f5adbd67fcf54c7c5913ae0234d062959992a1e8884e1a230ee",
    "slot": 28961,
    "slotInEpoch": 161,
    "slotsToEpochEnd": 7039,
    "syncProgress": "100.00"
}
{
  "major": 9,
  "minor": 0
}
```

Pick a target state time and calculated required synthesis slots
```bash
# Return to realtime:
sudo systemctl start systemd-timesyncd.service

# Finally choose a target time to synthesize to, which will be
# enough time to have the target network machines stood up,
# cleaned up, and prepped to receive new state.  For example,
# lets give ourselves about 1 hour of time to synthesize into
# the future:

# Current time
LC_TIME=C date -u
Fri May 17 16:42:24 UTC 2024

# Target time of about +1 hr: '2024-05-17 17:30:00Z'
# Get target timestamp
date -d '2024-05-17 17:30:00Z' +%s
1715967000

# Timestamp of start of chain is:
# START_TIME="2024-05-16T00:00:00Z"
date -d '2024-05-16T00:00:00Z' +%s
1715817600

# Calculate the synthesis slot requirement:
echo $((1715967000 - (1715817600 + 28961)))
120439
```

Synthesize the required synthesis slots
```bash
# Synthesize this amount
# NOTE: for conway synthesis, the following must be added
#   to node-config.json or the synthesis won't work:
#
#   "TestEnableDevelopmentHardForkEras": true,
#
rm "$DATA_DIR"/db/{clean,lock,protocolMagicId}
db-synthesizer-ng \
  --config "$DATA_DIR"/node-config.json \
  --db "$DATA_DIR"/db \
  --bulk-credentials-file "$DATA_DIR/bulk.creds.all.json" \
  -a \
  -s 120439
cp "$DATA_DIR"/protocolMagicId "$DATA_DIR"/db/

# Analyze the final state:
db-analyser-ng \
  --db $DATA_DIR/db \
  cardano \
  --config $DATA_DIR/node-config.json
[0.423245907s] Started OnlyValidation
[0.42349263s] Done
ChainDB tip: At (Block {blockPointSlot = SlotNo 149398, blockPointHash = c3a2ae6d7d90a4c1770a721d0c1969625c3822236bb48eb779956246f047d840})

# Backup the final state:
cp -a "$DATA_DIR"/db \
  "$DATA_DIR"/db-conway-prot-9-slot-149398-2024-05-17-17-30
```

Transfer fresh state to a target
```bash
# Rsync the state to a block producer machine
rsync \
  -e 'ssh -F .ssh_config' \
  -z --zc=zstd \
  -a --info=progress2 \
  "$DATA_DIR/db" \
  "${ENV}1-bp-a-1":/root/
```

Place new secrets and encrypt them
```bash
# Update .sops.yaml, if needed, with new env and machine age keys so encryption
# is done properly and automatically with the commands below.
# Then, move the secrets into their place and encrypt:
cp -a workbench/custom/envs/$ENV secrets/envs/
cp -a workbench/custom/groups/${ENV}1 secrets/groups/
cp -a workbench/custom/groups/${ENV}2 secrets/groups/
cp -a workbench/custom/groups/${ENV}3 secrets/groups/
fd -t f . secrets/envs/$ENV -x just sops-encrypt-binary
fd -t f . secrets/groups/${ENV}1 -x just sops-encrypt-binary
fd -t f . secrets/groups/${ENV}2 -x just sops-encrypt-binary
fd -t f . secrets/groups/${ENV}3 -x just sops-encrypt-binary

# Note: if not all files are overwritten in the target secrets directory, they
# will be double-encrypted. To avoid that, you can check for files which only
# exist in the target and git restore the double-encryption.
diff -qr workbench/custom/envs/$ENV/ secrets/envs/$ENV/ | grep Only
diff -qr workbench/custom/groups/${ENV}1/ secrets/groups/${ENV}1/ | grep Only
diff -qr workbench/custom/groups/${ENV}2/ secrets/groups/${ENV}2/ | grep Only
diff -qr workbench/custom/groups/${ENV}3/ secrets/groups/${ENV}3/ | grep Only

# Avoid the double-encryption
git restore $FILE_ONLY_IN_TARGET_DIR
```

Prepping remote machines
```bash
# If machines have pre-existing state, node can be stopped and state cleaned
# from the machines preferably 1 group at a time to avoid costly mistakes.
# Ensure silences are appropriately labels or you are likely to have alerts paging you.
just ssh-for-each "'<ENV>1*'" -- \
  "'systemctl stop cardano-node; rm -rf /var/lib/cardano-node'"

just ssh-for-each "'<ENV>2*'" -- \
  "'systemctl stop cardano-node; rm -rf /var/lib/cardano-node'"

just ssh-for-each "'<ENV>3*'" -- \
  "'systemctl stop cardano-node; rm -rf /var/lib/cardano-node'"

# From the first block producer machine state was rsync'd to,
# place the state so it is ready to be started
just ssh ${ENV}1-bp-a-1
rm -rf "/var/lib/cardano-node/db-$ENV"
cp -a /root/db "/var/lib/cardano-node/db-$ENV"
chown cardano-node:cardano-node /var/lib/cardano-node
```

Deploying the first machine with new state
```bash
# Now, deploy the machine to apply new secrets, config and
# start with the new state
just apply "${ENV}1-bp-a-1"
```

Deploying the rest of the cluster
```bash
# Once the block producer is running and making new blocks the other
# machines can be started, preferably one by one, relays from each
# group first, then the corresponding block producers for each group.
#
# Clean state can also be rsync'd from machine to machine to speed up
# the process if the chain state is big.
```
