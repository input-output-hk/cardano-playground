## Advanced Configuration: Preview Testnet

There is currently no pre-release version available for the preview environment.

The latest version available is cardano-node release `10.4.1`.

#### Configuration files

Compatible with cardano-node release [10.4.1](https://github.com/IntersectMBO/cardano-node/releases/tag/10.4.1)

```
NOTE:
The non-block-producer node config has `PeerSharing` enabled by
default, so should not be used with block-producers.

Additionally, avoid connecting a block-producer not using p2p to a p2p
PeerSharing enabled relay as the block-producer's IP will be leaked.
```

- [Node Config (Non-block-producers -- see note above)](environments-pre/preview/config.json)
- [Node Config (Block-producers)](environments-pre/preview/config-bp.json)
- [DB Sync Config](environments-pre/preview/db-sync-config.json)
- [Submit API Config](environments-pre/preview/submit-api-config.json)
- [Node Topology](environments-pre/preview/topology.json)
- [Node Topology (Genesis mode)](environments-pre/preview/topology-genesis-mode.json)
- [Peer Snapshot](environments-pre/preview/peer-snapshot.json)
- [Byron Genesis](environments-pre/preview/byron-genesis.json)
- [Shelley Genesis](environments-pre/preview/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/preview/alonzo-genesis.json)
- [Conway Genesis](environments-pre/preview/conway-genesis.json)
- [Compiled guardrails script](environments-pre/preview/guardrails-script.plutus)

#### UTXO-HD

Users migrating from a previous version of the node should read the [release
notes](https://github.com/IntersectMBO/cardano-node/releases/tag/10.4.1) and
the consensus [migration guide](https://ouroboros-consensus.cardano.intersectmbo.org/docs/for-developers/utxo-hd/migrating)
to properly configure the node and convert the database such that a replay from
genesis can be avoided.

#### Ouroboros Genesis Mode

For those preferring to use Genesis mode over bootstrap peers, the Genesis mode
topology file given above can be used in place of the default topology file.
The following requirements will also need to be met:

* The node config file will need to have `ConsensusMode` set to `GenesisMode`

* The peer snapshot file, provided above, will need to exist at the path
declared at `peerSnapshotFile` in the genesis mode topology file: an absolute
path, or a relative path with respect to the node binary directory

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Protocol Parameter Change proposals.

Guardrails script address: `addr_test1wrazf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqf68ll6`
Guardrails script UTxO: `f3f61635034140e6cec495a1c69ce85b22690e65ab9553ef408d524f58183649#0`
