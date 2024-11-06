# Cardano chain manipulation
* The commands below can be obtained from the cardano-playground `test` or
  `ops` devShell, or from the cardano-node release binary and a bash shell.

* From within a clone of the cardano-playground repo, running `direnv allow` if
  direnv is installed, or `nix develop` will be sufficient to enter an `ops`
  default devShell for `x86_64-linux` systems.

* Note that nix `2.17.0` or greater must be installed and configured with
  `experimental-features = nix-command flakes fetch-closure` to enter the
  devShell successfully.

## To analyze a chain
* Ensure that cardano-node has already been stopped prior to running these commands.

* Adjust the `$DATA_DIR` env var or the general `--db` and `--config` arg paths
  below for what is appropriate in your environment.

* Analyze what slot the current state is at:
```bash
db-analyser \
  --db "$DATA_DIR/db" \
  cardano \
  --config "$DATA_DIR/config.json"
[51.869065929s] Started OnlyValidation
[51.869216222s] Done
ChainDB tip: At (Block {blockPointSlot = SlotNo 20812218, blockPointHash = 549b44832acaad8da9248a56198abfe4be16605da92c871f57afceed34b24562})
```

## To truncate a chain
* Decide where to truncate the chain.  In this example we pick a
  truncate-after-slot which will be the start of epoch 237 * 86400 slots/epoch
  which equates to 20476800.

* The same procedure can instead use the `--truncate-after-block` option if
  preferred.
```bash
db-truncater \
 --db "$DATA_DIR/db" \
 --truncate-after-slot 20476800 \
 cardano \
 --config "$DATA_DIR/config.json"

# Verify the truncation after each iteration with db-analyser
db-analyser \
  --db "$DATA_DIR/db" \
  cardano \
  --config "$DATA_DIR/config.json"
[29.119164783s] Started OnlyValidation
[29.119413325s] Done
ChainDB tip: At (Block {blockPointSlot = SlotNo 20476800, blockPointHash = a20bfd2002f521cfd5d101996e72fb835ec3b10eda738c517060aa78e2591f89})
```

## To synthesize a chain
* With a bulk credentials file, synthesis of blocks is straightforward.
* TIP: bulk credentials file can be created with the `just save-bulk-creds` recipe.

* The following example shows synthesis of a particular number of slots.

* The same procedure can instead use the `-e` option if preferred to synthesize
  for a number of epochs.
```bash
# First preserve the protocolMagicId file
cp "$DATA_DIR"/db/protocolMagicId "$DATA_DIR/"

# If it exists, delete the gsm directory which may contain a `CaughtUpMarker`
# file.  If this directory is present, it will prevent db-synthesizer from
# working.
rm -rf "$DATA_DIR"/db/gsm

# Prep for synthesis
rm -rf "$DATA_DIR"/db/{clean,lock,protocolMagicId}

# Synthesize the desired number of slots
db-synthesizer \
  --config "$DATA_DIR"/config.json \
  --db "$DATA_DIR"/db \
  --bulk-credentials-file "$DATA_DIR/bulk.creds.secret.$ENV.$COMMIT.$DATE.pools.json"  \
  -a \
  -s 58779

--> forger count: 3
--> opening ChainDB on file system with mode: OpenAppend
--> starting at: SlotNo 26093427
--> epoch size: EpochSize 86400
--> will process until: ForgeLimitSlot (SlotNo 58779)
--> forged and adopted 2929 blocks; reached SlotNo 26152206
--> done; result: ForgeResult {resultForged = 2929}

# Copy protocolMagicId back to the db dir
cp "$DATA_DIR/protocolMagicId" "$DATA_DIR/db/"
```

## Run cardano with the synthetic chain
* By calculating the date the chain tip exists at, a local system can be set to
  match this tip and cardano-node started to verify the chain still runs
  properly and forges blocks with the bulk credentials file.
```bash
# Calculate genesis unix timestamp:
# From shelley genesis in this example: "systemStart": "2023-06-15T00:30:00Z"
date -u -d "2023-06-15T00:30:00Z" +%s
1686789000

# Add the slot tip of the synthesized chain from above to the unix timestamp of
# the chain systemStart.
echo $((1686789000 + 26152206))
1712941206

# Convert the result to a date.
LC_TIME=C date -u -d @1712941206
Fri Apr 12 17:00:06 UTC 2024

# Set the system date about 2 minutes prior to chain tip to allow for replay
# time on startup.
sudo systemctl stop systemd-timesyncd.service
sudo date -s '2024-04-12T16:58:00Z'

# Start node
cardano-node run \
  --config "$DATA_DIR/config.json" \
  --database-path "$DATA_DIR/db" \
  --socket-path "$(pwd)/node.socket" \
  --topology '$DATA_DIR/topology.json" \
  --bulk-credentials-file "$DATA_DIR/bulk.creds.secret.$ENV.$COMMIT.$DATE.pools.json" \
  +RTS -N2 -A16m -qg -qb -M3584.000000M -RTS \
  | tee -a "node-$ENV.log"
```
