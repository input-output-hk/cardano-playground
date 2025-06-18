## Advanced Configuration: Pre-Production Testnet

Users wanting to test a cardano-node pre-release version on the pre-production
environment may obtain compatible configuration files below.

The latest version available is cardano-node pre-release `10.5.0`.

#### Configuration files

Compatible with cardano-node pre-release [10.5.0](https://github.com/IntersectMBO/cardano-node/releases/tag/10.5.0)

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
- [Peer Snapshot](environments-pre/preprod/peer-snapshot.json)
- [Byron Genesis](environments-pre/preprod/byron-genesis.json)
- [Shelley Genesis](environments-pre/preprod/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/preprod/alonzo-genesis.json)
- [Conway Genesis](environments-pre/preprod/conway-genesis.json)
- [Compiled guardrails script](environments-pre/preprod/guardrails-script.plutus)

#### Ouroboros Genesis Mode

Ouroboros genesis mode is now the default consensus mode on preview and preprod
testnets starting with node `10.5.0`.  If needed, use of praos mode and the
bootstrap peers found in the above topology file can be reverted to by setting:

* Node config's `ConsensusMode` option to a value of `PraosMode`

#### UTXO-HD

Users migrating from a node version older than `10.4.1` should also read the [10.4.1 release
notes](https://github.com/IntersectMBO/cardano-node/releases/tag/10.4.1) and
the consensus [migration guide](https://ouroboros-consensus.cardano.intersectmbo.org/docs/for-developers/utxo-hd/migrating)
to properly configure the node and convert the database such that a replay from
genesis can be avoided.

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Update Protocol Parameter proposals.

Guardrails script address: `addr_test1wrazf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqf68ll6`
Guardrails script UTxO: `9aabbac24d1e39cb3e677981c84998a4210bae8d56b0f60908eedb9f59efffc8#0`
