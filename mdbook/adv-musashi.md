## Advanced Configuration: Musashi Testnet

The Musashi Testnet (MusashiNet) is a prototype environment for evaluating
the Ouroboros Leios protocol extension.  It is an advanced environment intended
for testing and not for production use.

The latest version available is the `ouroboros-leios` prototype build
[`prototype-2026w35`](https://github.com/input-output-hk/ouroboros-leios/releases/tag/prototype-2026w35).

Network magic: `164`

#### Configuration files

Compatible with the `ouroboros-leios` prototype build [`prototype-2026w35`](https://github.com/input-output-hk/ouroboros-leios/releases/tag/prototype-2026w35)

```
NOTE:
* Legacy tracing system is no longer available.  See additional notes below.

* Avoid connecting PeerSharing enabled nodes to a block producer using
`InitiatorOnlyMode` as the block producer's IP will be leaked.
```

- [Node Config](environments-pre/leios/config.json)
- [Tracer Config](environments-pre/leios/tracer-config.json)
- [DB Sync Config](environments-pre/leios/db-sync-config.json)
- [Submit API Config](environments-pre/leios/submit-api-config.json)
- [Node Topology](environments-pre/leios/topology.json)
- [Peer Snapshot](environments-pre/leios/peer-snapshot.json)
- [Byron Genesis](environments-pre/leios/byron-genesis.json)
- [Shelley Genesis](environments-pre/leios/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/leios/alonzo-genesis.json)
- [Conway Genesis](environments-pre/leios/conway-genesis.json)
- [Dijkstra Genesis](environments-pre/leios/dijkstra-genesis.json)

#### Consensus Mode

The Musashi Testnet currently runs in Praos consensus mode.  The node config's
`ConsensusMode` option is set to `PraosMode`.

#### Additional Information

- [Musashi Network](https://www.musashi.network/)
- [Ouroboros Leios — Cardano Scaling](https://leios.cardano-scaling.org/)
- [MusashiNet testnet — getting started](https://leios.cardano-scaling.org/docs/testnet/getting-started/)
