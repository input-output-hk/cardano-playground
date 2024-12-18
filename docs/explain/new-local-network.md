# Creating a local test network

The cardano-playground `ops` devShell, includes the release and pre-release versions
of the `cardano-testnet` binary from the cardano-node repo as `cardano-testnet`
and `cardano-testnet-ng`.

A `just` recipe wrapper allows for easy selection between the two versions and
automatically handles the appropriate `cardano-node` and `cardano-cli` binary
path exports required by the underlying `cardano-testnet` binary tool.

For basic `cardano-testnet` invocation:
```bash
# If using direnv:
direnv allow

# Otherwise:
nix develop

# To run the release version, provide isNg as `false`,
# otherwise `true` for pre-release.
❯ just cardano-testnet
usage:
    just cardano-testnet isNg *ARGS

# Example for release versioning:
❯ just cardano-testnet false ...
```

For those not wanting or able to use the cardano-playground `ops` devShell, the
underlying `cardano-testnet` tool from the node repo can be used directly by
either following the instructions at the
[cardano-node-wiki](https://github.com/input-output-hk/cardano-node-wiki/wiki/launching-a-testnet)
or exporting the path to the cli and node binaries as `CARDANO_CLI` and `CARDANO_NODE`.

The `*ARGS` expected for the just `cardano-testnet` recipe are those explained
by the help output of the underlying binary tool:
```bash
❯ just cardano-testnet true cardano --help
Usage: cardano-testnet cardano [--num-pool-nodes COUNT]
  [ --shelley-era
  | --allegra-era
  | --mary-era
  | --alonzo-era
  | --babbage-era
  | --conway-era
  ]
  [--max-lovelace-supply WORD64]
  [--enable-p2p BOOL]
  [--nodeLoggingFormat LOGGING_FORMAT]
  [--num-dreps NUMBER]
  [--enable-new-epoch-state-logging]
  --testnet-magic INT
  [--epoch-length SLOTS]
  [--slot-length SECONDS]
  [--active-slots-coeff DOUBLE]

  Start a testnet in any era

Available options:
<...snip...>
```
Spinning up a new Conway era network with one pool actively forging is as easy as:
```bash
❯ just cardano-testnet false cardano --testnet-magic 42
<...snip...>
Testnet is running.  Type CTRL-C to exit.
```

Under the hood, `cardano-testnet` is using the `cardano-cli latest genesis
create-testnet-data` sub-command to generate initial new chain network state
configuration and then further customizing and processing this state data as
needed.

Compared with the more time consuming and intricate method of chain spin up for
new operations chains described in [new-network.md](new-network.md), this is a
nice, fast way to start a customized local chain for testing.

All generated `cardano-testnet` configuration data can be found at the paths
indicated in command's verbose output.

An example tip query of this local testnet would be:
```bash
❯ cardano-cli latest query tip \
  --socket-path /tmp/testnet-test-97c5afb9048644f7/socket/node1/sock \
  --testnet-magic 42
{
    "block": 51,
    "epoch": 1,
    "era": "Conway",
    "hash": "3f310a97284cec9968881daf8d73c876a8814fb883f6d17b532ea06065d77aea",
    "slot": 846,
    "slotInEpoch": 346,
    "slotsToEpochEnd": 154,
    "syncProgress": "100.00"
}
```

An example of the associated process state of this testnet would be:
```bash
❯ pgrep -af cardano-
743929 just cardano-testnet false cardano --conway-era --testnet-magic 42
743931 bash /tmp/just-wkPyIQ/cardano-testnet false cardano --conway-era --testnet-magic 42
743934 cardano-testnet cardano --conway-era --testnet-magic 42
743979 /nix/store/kjvvsa00kv6yhvmaylcjxvxl7rcy54ld-cardano-node-exe-cardano-node-10.1.3/bin/cardano-node run \
  --config /tmp/testnet-test-97c5afb9048644f7/configuration.yaml \
  --topology /tmp/testnet-test-97c5afb9048644f7/node-data/node1/topology.json \
  --database-path /tmp/testnet-test-97c5afb9048644f7/node-data/node1/db \
  --shelley-kes-key /tmp/testnet-test-97c5afb9048644f7/pools-keys/pool1/kes.skey \
  --shelley-vrf-key /tmp/testnet-test-97c5afb9048644f7/pools-keys/pool1/vrf.skey \
  --byron-delegation-certificate /tmp/testnet-test-97c5afb9048644f7/pools-keys/pool1/byron-delegation.cert \
  --byron-signing-key /tmp/testnet-test-97c5afb9048644f7/pools-keys/pool1/byron-delegate.key \
  --shelley-operational-certificate /tmp/testnet-test-97c5afb9048644f7/pools-keys/pool1/opcert.cert \
  --socket-path ./socket/node1/sock \
  --port 33303 \
  --host-addr 127.0.0.1
```

For those wanting to run a custom network in a local docker container, the
`cardano-testnet` configuration state can also be used as a quick starting
point for a docker compose file like the following:
```yaml
services:
  cardano-node:
    image: ghcr.io/intersectmbo/cardano-node:${CARDANO_NODE_VERSION:-10.1.3}
    environment:
      - CARDANO_CONFIG=/opt/cardano/workbench/config.json
      - CARDANO_TOPOLOGY=/opt/cardano/workbench/topology.json
      - CARDANO_DATABASE_PATH=/opt/cardano/workbench/data
      - CARDANO_SOCKET_PATH=/opt/cardano/workbench/ipc/socket
      - CARDANO_LOG_DIR=/opt/cardano/workbench/logs
      - CARDANO_BIND_ADDRESS=0.0.0.0
      - CARDANO_PORT=3001
      - CARDANO_BLOCK_PRODUCER=true
      - CARDANO_SHELLEY_KES_KEY=/opt/cardano/workbench/kes.skey
      - CARDANO_SHELLEY_VRF_KEY=/opt/cardano/workbench/vrf.skey
      - CARDANO_SHELLEY_OPERATIONAL_CERTIFICATE=/opt/cardano/workbench/opcert.cert
    command:
      - run
    volumes:
      - ./new-testnet:/opt/cardano/workbench
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"
```

From the same directory that the above docker compose file is created in, the
following sequence of commands is an example of moving new testnet configuration
state into a docker container:
```bash
# Start a local testnet so that all configuration state is created:
❯ just cardano-testnet false cardano --conway-era --testnet-magic 42 --slot-length 1

# Once running, stop the testnet with <CTRL-C> and assign the `Workspace` to a variable:
WORKSPACE=/tmp/...

# Make a docker state mounting dir and copy relevant `cardano-testnet` config state into it
mkdir -p new-testnet/byron
cp $WORKSPACE/{alonzo,shelley,conway}-genesis.json new-testnet/
cp $WORKSPACE/byron/genesis.json new-testnet/byron/
cp $WORKSPACE/configuration.yaml new-testnet/config.json
cp $WORKSPACE/node-data/node1/topology.json new-testnet/
cp $WORKSPACE/pools-keys/pool1/kes.skey new-testnet/
cp $WORKSPACE/pools-keys/pool1/vrf.skey new-testnet/
cp $WORKSPACE/pools-keys/pool1/opcert.cert new-testnet/

# Start docker:
docker compose up
```

If the `--slot-length 1` arg is not included as shown above, `cardano-testnet`
will default to slots of 100 milliseconds making it difficult to manually move
the `cardano-testnet` generated config data into docker and get docker started
before the node can no longer forge because it missed too much time.

To remedy this, the start times in the byron and shelley genesis files can be
edited to a more suitable start time, followed by rehashing them and updating
the hashes in the node configuration file.
