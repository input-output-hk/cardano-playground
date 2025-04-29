## Advanced Configuration: Pre-Production Testnet

There is currently no pre-release version available for the preprod environment.

The latest version available is cardano-node release `10.3.1`.

#### Configuration files

Compatible with cardano-node release [10.3.1](https://github.com/IntersectMBO/cardano-node/releases/tag/10.3.1)

```
NOTE:
The non-block-producer node config has `PeerSharing` enabled by
default, so should not be used with block-producers.

Additionally, avoid connecting a block-producer not using p2p to a p2p
PeerSharing enabled relay as the block-producer's IP will be leaked.
```

- [Node Config (Non-block-producers -- see note above)](environments-pre/preprod/config.json)
- [Node Config (Block-producers)](environments-pre/preprod/config-bp.json)
- [DB Sync Config](environments-pre/preprod/db-sync-config.json)
- [Submit API Config](environments-pre/preprod/submit-api-config.json)
- [Node Topology](environments-pre/preprod/topology.json)
- [Node Topology (Genesis mode)](environments-pre/preprod/topology-genesis-mode.json)
- [Peer Snapshot](environments-pre/preprod/peer-snapshot.json)
- [Byron Genesis](environments-pre/preprod/byron-genesis.json)
- [Shelley Genesis](environments-pre/preprod/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/preprod/alonzo-genesis.json)
- [Conway Genesis](environments-pre/preprod/conway-genesis.json)
- [Compiled guardrails script](environments-pre/preprod/guardrails-script.plutus)

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
Treasury Withdrawal and Update Protocol Parameter proposals.

Guardrails script address: `addr_test1wrazf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqf68ll6`
Guardrails script UTxO: `9aabbac24d1e39cb3e677981c84998a4210bae8d56b0f60908eedb9f59efffc8#0`
