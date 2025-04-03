## Advanced Configuration: Preview Testnet

Users wanting to test a cardano-node pre-release version on the preview
environment may obtain compatible configuration files below.

The latest version available is cardano-node pre-release `10.3.0`.

#### Configuration files

Compatible with cardano-node pre-release [10.3.0](https://github.com/IntersectMBO/cardano-node/releases/tag/10.3.0)

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

#### Ouroboros Genesis Mode

For those preferring to use Genesis mode over bootstrap peers, the Genesis mode
topology file given above can be used in place of the default topology file.
The following requirements will also need to be met:

* The node config will need to have `ConsensusMode` set to `GenesisMode`

* The peer snapshot file, provided above, will need to exist at the path
declared at `peerSnapshotFile` in the genesis mode topology file: an absolute
path, or a relative path with respect to the node server invocation directory

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Protocol Parameter Change proposals.

Guardrails script address: `addr_test1wrazf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqf68ll6`
Guardrails script UTxO: `f3f61635034140e6cec495a1c69ce85b22690e65ab9553ef408d524f58183649#0`
