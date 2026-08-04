# Creating and updating pools in playground

Sometimes we want to add a single pool to an existing network, or update a pool
that already exists -- rotate its KES key, add a BLS key, or publish ticker
metadata. All of this is done with the cardano-parts nix jobs exposed locally as
`nix run .#job-*`. The parameters accepted by each job, and the job definitions
themselves, live in the cardano-parts repo `flakeModules/jobs.nix` file.

## One pool per run, one directory per group

Run these jobs for a **single pool at a time**, and point `STAKE_POOL_DIR` at
that pool's own group directory under `secrets/groups/<group>`:

```bash
POOL_NAMES="leios1-bp-a-1" STAKE_POOL_DIR=secrets/groups/leios1
```

This is what keeps each pool's secrets isolated, and it is worth understanding
before batching:

`job-create-stake-pool-keys` generates **one** owner wallet (`owner.mnemonic`)
and **one** reward stake key at the `STAKE_POOL_DIR` level, then copies them into
every pool named in that run. Passing multiple `POOL_NAMES` in a single run
therefore makes those pools **share a single owner wallet and reward account**.
That is intentional for a throwaway local network -- the `just` demo funds
`sp-1 sp-2 sp-3` from one shared wallet on purpose -- but pools that are meant to
be independent must each get their own `secrets/groups/<group>` directory and be
created, registered, and updated in separate runs. The same one-at-a-time rule
applies to the register and re-register jobs below, so that a run only ever
touches the keys under the single group directory you passed.

## 1. Create the pool keys

```bash
# The CURRENT_KES_PERIOD can be calculated from dividing the absolute slot height by slots per kes period:
#   SLOT=$(cardano-cli query tip | jq .slot)
#   SLOTS_PER_KES_PERIOD=$(jq -r .slotsPerKESPeriod < "$PATH_TO/shelley-genesis.json")
#   CURRENT_KES_PERIOD=$(( $SLOT / $SLOTS_PER_KES_PERIOD ))
ENV=sanchonet \
  CURRENT_KES_PERIOD="562" \
  POOL_NAMES="${ENV}1-bp-a-1" \
  STAKE_POOL_DIR=secrets/groups/${ENV}1 \
  TESTNET_MAGIC=4 \
  USE_ENCRYPTION=true \
  USE_DECRYPTION=true \
  ERA_CMD="conway" \
  nix run .#job-create-stake-pool-keys
```

## 2. Register the pool

Assuming that a rich key address or equivalent is already available and funded,
set the desired parameters for the pool:

```bash
# Here we turn on debug and set SUBMIT_TX false to review the transaction #
# before submitting it to the network.  Pool metadata was not setup for this
# temporary pool.
ENV="sanchonet" \
  DEBUG="true" \
  POOL_NAMES="${ENV}1-bp-a-1" \
  STAKE_POOL_DIR=secrets/groups/${ENV}1 \
  ERA_CMD="conway" \
  PAYMENT_KEY="secrets/envs/sanchonet/utxo-keys/rich-utxo" \
  POOL_MARGIN="0.2" \
  POOL_PLEDGE="350000000000" \
  POOL_RELAY="$ENV-node.play.dev.cardano.org" \
  POOL_RELAY_PORT="3001" \
  UNSTABLE=false \
  USE_DECRYPTION=true \
  USE_ENCRYPTION=true \
  SUBMIT_TX="false" \
  nix run .#job-register-stake-pools
```

This will register the pool on chain and fund the pledge.  The pool will start
forging blocks as early as the third epoch rollover after registration assuming
sufficient stake.  The delay is required for stake to propagate through the
"mark", "set", "go" phases at which point forging occurs.

Some useful commands to monitor pool stake are:
```bash
POOL_ID=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-pool.id)
POOL_HASH=$(cardano-cli latest query pool-state --stake-pool-id "$POOL_ID" | jq -r 'to_entries[].key')

# Pledge address and rewards payment addresses
OWNER_PAY=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-owner-payment-stake.addr)
REWARD_PAY=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-reward-payment-stake.addr)

# Owner and rewards stake addresses
OWNER_STAKE=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-owner-stake.addr)
REWARD_STAKE=$(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/"$POOL_NAMES"-reward-stake.addr)

# Verify pledge
cardano-cli latest query utxo --address "$OWNER_PAY"

# Verify pool unspent rewards
cardano-cli latest query stake-address-info --address "$REWARD_STAKE"

# Verify pool state
cardano-cli latest query pool-state --stake-pool-id "$POOL_ID"

# Verify mark, set, go pool and network stake:
cardano-cli latest query stake-snapshot --stake-pool-id "$POOL_ID"

# Show current expected forge fraction for "go":
cardano-cli latest query stake-snapshot --stake-pool-id "$POOL_ID" | jq -r '(.pools | to_entries[].value.stakeGo) / .total.stakeGo * 100'

# Show all delegation to the pool:
cardano-cli latest query spo-stake-distribution --all-spos --output-json | jq ".[] | select(.[0] == \"$POOL_HASH\")"

# Sum all delegation to the pool:
cardano-cli latest query spo-stake-distribution --all-spos --output-json | jq "[.[] | select(.[0] == \"$POOL_HASH\")] | map(.[1]) | add"

# List all network pools:
cardano-cli latest query stake-pools
```

## 3. Updating a pool via re-registration

To change something about a pool that is *already* registered -- add a BLS key,
publish ticker metadata, change relays/margin/etc. -- you re-register it. A stake
pool registration certificate is **absolute**: it re-declares the pool's entire
parameter set, not a delta. So re-registration means submitting a fresh cert with
the same parameters the pool has on chain today, changing only what you intend --
a mismatched pledge/margin/relay/metadata would silently change the pool at the
next epoch boundary.

`job-reregister-stake-pools` does this. It reuses the pool's existing
cold/vrf/owner/reward keys and, unlike first registration, does **not** register
stake addresses, delegate, create pledge outputs, or pay a deposit
(re-registration reuses the pool's original deposit) -- the transaction carries
only the pool cert and pays the tx fee. Pass the same `POOL_*` inputs the pool
was first registered with, and, as above, one pool per run with its group's
`STAKE_POOL_DIR`.

### Verify the current params first

Because the cert is absolute, query the pool's live params and feed them back
unchanged -- don't trust your memory or the job defaults. Per group (needs a
synced node socket and the network magic):

```bash
POOL_ID=$(just sops-decrypt-binary secrets/groups/leios1/no-deploy/leios1-bp-a-1-pool.id)
cardano-cli dijkstra query pool-params --stake-pool-id "$POOL_ID"   # or: query pool-state
```

Most fields reproduce automatically from the reused keys (`spsOwners`,
`spsAccountId` reward account, `spsVrf`, pool id). The ones you must pass to
match are `spsCost`, `spsMargin`, `spsPledge`, and `spsRelays`. **Three job
defaults are not safe to rely on -- always set them explicitly to the queried
values:**

- `POOL_PLEDGE` defaults to `10000000000000` (10M ADA). If the pool is pledged
  at a different amount, re-registering at the default leaves it pledge-not-met
  and it stops earning.
- `POOL_COST` defaults to `500000000` (500 ADA). Set it to the pool's `spsCost`
  -- e.g. where a network has lowered `minPoolCost` (preview -> 170 ADA), pass
  `POOL_COST=170000000` rather than bumping the pool back to 500.
- `POOL_RELAY_PORT` has no default; omitting it drops the port from the relay.

Then build without submitting and diff the real transaction against the query --
only the intended additions should appear:

```bash
# add SUBMIT_TX=false to the invocation below, then:
cardano-cli dijkstra transaction view --tx-file leios1-bp-a-1-tx-pool-rereg.txsigned
```

Every param (cost/margin/pledge/relays/owners/reward/vrf/poolId) must match the
`pool-params` query; only `leiosKey` (BLS) and `metadata` (ticker) should be new.
The transaction should also be fee-only -- one input, change back minus fee, no
deposit and no pledge output. If that all holds, re-run without `SUBMIT_TX=false`
to submit. The change takes effect at the next epoch boundary.

### Adding a BLS key (Leios / dijkstra)

BLS keys are a Leios feature and are generated with the dijkstra-era cli, so
these steps require `ERA_CMD=dijkstra`. First mint a BLS key pair for the pool --
this only adds `<pool>-bls.{skey,vkey}` to the group's `deploy/` directory,
leaving cold/vrf/kes untouched, and it skips any pool that already has one:

```bash
POOL_NAMES="leios1-bp-a-1" \
  STAKE_POOL_DIR=secrets/groups/leios1 \
  ERA_CMD=dijkstra \
  TESTNET_MAGIC=<magic> \
  USE_ENCRYPTION=true \
  nix run .#job-create-stake-pool-bls-keys
```

Then re-register the pool with `USE_BLS=true` to bind the key on chain (the job
adds `--bls-signing-key-file` only for the dijkstra cert):

```bash
POOL_NAMES="leios1-bp-a-1" \
  STAKE_POOL_DIR=secrets/groups/leios1 \
  ERA_CMD=dijkstra \
  TESTNET_MAGIC=<magic> \
  USE_BLS=true \
  PAYMENT_KEY=<funded payment key> \
  POOL_MARGIN=<current> POOL_PLEDGE=<current> \
  POOL_RELAY=<current> POOL_RELAY_PORT=<current> \
  USE_DECRYPTION=true USE_ENCRYPTION=true \
  SUBMIT_TX=false \
  nix run .#job-reregister-stake-pools
```

### Publishing ticker metadata

A pool's ticker (and name/description/homepage) is off-chain: the registration
cert only stores a metadata URL plus its hash, and the ticker lives in the JSON
served at that URL. Playground serves these as static files from the webserver
under the short `pools.<domain>` vhost (`static/pools.<domain>/<group>.json`),
kept separate from the book so the on-chain URL stays within its 64-byte limit.
The files are one-per-group (one pool per group), e.g.:

```
https://pools.play.dev.cardano.org/leios1.json
  -> {"name":"IOG Leios Pool 1","ticker":"IOG1","description":"...","homepage":"..."}
```

Metadata rules to respect when editing a file: the whole JSON must be <=512 bytes,
the ticker 3-5 of `[A-Z0-9]`, and the resulting URL <=64 bytes. Publish the file
first (apply the `pools.<domain>` route53 record and deploy the webserver), since
the job hashes the *live* URL -- the on-chain hash then always matches what is
served.

To register the metadata, set `POOL_METADATA_BASE_URL`; the re-register job
appends the pool's group file (`<group>.json`, derived from the pool name) and
hashes it. This composes with the BLS step -- one re-registration can carry both:

```bash
POOL_NAMES="leios1-bp-a-1" \
  STAKE_POOL_DIR=secrets/groups/leios1 \
  ERA_CMD=dijkstra \
  TESTNET_MAGIC=<magic> \
  USE_BLS=true \
  POOL_METADATA_BASE_URL=https://pools.play.dev.cardano.org \
  PAYMENT_KEY=<funded payment key> \
  POOL_MARGIN=<current> POOL_PLEDGE=<current> \
  POOL_RELAY=<current> POOL_RELAY_PORT=<current> \
  USE_DECRYPTION=true USE_ENCRYPTION=true \
  nix run .#job-reregister-stake-pools
```

## Running a custom node for submission

If a custom configured cardano-node needs to be running to facilitate submission to a
custom network defined outside of iohk-nix, the node can be run by setting
appropriate parameters to the `.#run-cardano-node` job as the following example
shows:
```bash
unset ENVIRONMENT
unset UNSTABLE
export DATA_DIR=workbench/sanchonet
export NODE_CONFIG=$(pwd)/docs/environments-tmp/sanchonet/config.json
export NODE_TOPOLOGY=$(pwd)/docs/environments-tmp/sanchonet/topology.json
export SOCKET_PATH=$(pwd)/node-sanchonet.socket
nix run .#run-cardano-node
```

See all configurable `.#run-cardano-node` nix parameters at the cardano-parts
repo in the `flakeModules/entrypoints.nix` file. If preferred, the cardano-node binary can
be directly run from the devShell.
