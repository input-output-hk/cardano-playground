## Advanced Configuration: Preview Testnet

Users wanting to test a cardano-node pre-release version on the preview
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

- [Node Config](environments-pre/preview/config.json)
- [Tracer Config](environments-pre/preview/tracer-config.json)
- [DB Sync Config](environments-pre/preview/db-sync-config.json)
- [Submit API Config](environments-pre/preview/submit-api-config.json)
- [Node Topology](environments-pre/preview/topology.json)
- [Peer Snapshot](environments-pre/preview/peer-snapshot.json)
- [Checkpoints](environments-pre/preview/checkpoints.json)
- [Byron Genesis](environments-pre/preview/byron-genesis.json)
- [Shelley Genesis](environments-pre/preview/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/preview/alonzo-genesis.json)
- [Conway Genesis](environments-pre/preview/conway-genesis.json)
- [Compiled guardrails script](environments-pre/preview/guardrails-script.plutus)

#### Ouroboros Genesis Mode

Ouroboros genesis mode is now the default consensus mode on preview and preprod
testnets starting with node `10.5.0`.  If needed, use of praos mode and the
bootstrap peers found in the above topology file can be reverted to by setting:

* Node config's `ConsensusMode` option to a value of `PraosMode`

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Protocol Parameter Change proposals.

Guardrails script address: `addr_test1wrazf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqf68ll6`
Guardrails script UTxO: `f3f61635034140e6cec495a1c69ce85b22690e65ab9553ef408d524f58183649#0`
