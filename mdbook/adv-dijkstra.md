## Advanced Configuration: Dijkstra Testnet

The Dijkstra testnet is an advanced environment for testing Dijkstra features.

It is currently in Conway protocol version 11 for a short time, during which
cardano-node `11.1.3` can be used to sync to it.  When cardano-node `11.2.0` is
pre-released, the dijkstra network config will be updated and re-published with
a hard fork to Dijkstra protocol version 12 to follow shortly after.

#### Configuration files

Compatible with cardano-node release [11.1.3](https://github.com/IntersectMBO/cardano-node/releases/tag/11.1.3)

```
NOTE:
* Legacy tracing system is no longer available.

* Avoid connecting PeerSharing enabled nodes to a block producer using
`InitiatorOnlyMode` as the block producer's IP will be leaked.
```

- [Node Config](environments-pre/dijkstra/config.json)
- [Tracer Config](environments-pre/dijkstra/tracer-config.json)
- [DB Sync Config](environments-pre/dijkstra/db-sync-config.json)
- [Submit API Config](environments-pre/dijkstra/submit-api-config.json)
- [Node Topology](environments-pre/dijkstra/topology.json)
- [Peer Snapshot](environments-pre/dijkstra/peer-snapshot.json)
- [Byron Genesis](environments-pre/dijkstra/byron-genesis.json)
- [Shelley Genesis](environments-pre/dijkstra/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/dijkstra/alonzo-genesis.json)
- [Conway Genesis](environments-pre/dijkstra/conway-genesis.json)
- [Dijkstra Genesis](environments-pre/dijkstra/dijkstra-genesis.json)
- [Compiled guardrails script](environments-pre/dijkstra/guardrails-script.plutus)

#### Ouroboros Genesis Mode

Ouroboros genesis mode is now the default consensus mode.  If needed, use of
praos mode and the bootstrap peers found in the above topology file can be
reverted to by setting:

* Node config's `ConsensusMode` option to a value of `PraosMode`

#### Faucet

A faucet is available at [https://faucet.dijkstra.play.dev.cardano.org/basic-faucet](https://faucet.dijkstra.play.dev.cardano.org/basic-faucet)

This faucet can be used to obtain test ADA as well as stake delegation for new
pools on the Dijkstra testnet.
