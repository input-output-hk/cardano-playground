## Advanced Configuration: Pre-Production Testnet

Users wanting to test a cardano-node pre-release version on the preprod
environment may obtain compatible configuration files below.

The latest version available is cardano-node release `11.1.0`.

#### Configuration files

Compatible with cardano-node release [11.1.0](https://github.com/IntersectMBO/cardano-node/releases/tag/11.1.0)

```
NOTE:
* Legacy tracing system is no longer available.

* Avoid connecting PeerSharing enabled nodes to a block producer using
`InitiatorOnlyMode` as the block producer's IP will be leaked.
```

- [Node Config](environments-pre/preprod/config.json)
- [Tracer Config](environments-pre/preprod/tracer-config.json)
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

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Update Protocol Parameter proposals.

Guardrails script address: `addr_test1wrazf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqf68ll6`
Guardrails script UTxO: `9aabbac24d1e39cb3e677981c84998a4210bae8d56b0f60908eedb9f59efffc8#0`
