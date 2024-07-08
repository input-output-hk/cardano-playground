## Advanced Configuration: Production (Mainnet)

Users wanting to test a cardano-node new release or pre-release version on the
mainnet environment may obtain compatible configuration files below.

#### Configuration files

Compatible with cardano-node pre-release [9.0.0](https://github.com/IntersectMBO/cardano-node/releases/tag/9.0.0)

```
NOTE:
The non-block-producer node config has `PeerSharing` enabled by
default, so should not be used with block-producers.

Additionally, avoid connecting a block-producer not using p2p to a p2p
PeerSharing enabled relay as the block-producer's IP will be leaked.
```

- [Node Config (Non-block-producers -- see note above)](environments-pre/mainnet/config.json)
- [Node Config (Block-producers)](environments-pre/mainnet/config-bp.json)
- [DB Sync Config](environments-pre/mainnet/db-sync-config.json)
- [Submit API Config](environments-pre/mainnet/submit-api-config.json)
- [Node Topology](environments-pre/mainnet/topology.json)
- [Byron Genesis](environments-pre/mainnet/byron-genesis.json)
- [Shelley Genesis](environments-pre/mainnet/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/mainnet/alonzo-genesis.json)
