## Advanced Configuration: Preview Testnet

Users wanting to test a cardano-node pre-release version on the preview
environment may obtain compatible configuration files below.

The latest version available is cardano-node pre-release `10.1.1-pre`.

#### Configuration files

Compatible with cardano-node pre-release [10.1.1-pre](https://github.com/IntersectMBO/cardano-node/releases/tag/10.1.1-pre)

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
- [Byron Genesis](environments-pre/preview/byron-genesis.json)
- [Shelley Genesis](environments-pre/preview/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/preview/alonzo-genesis.json)
- [Conway Genesis](environments-pre/preview/conway-genesis.json)
- [Compiled guardrails script](environments-pre/preview/guardrails-script.plutus)
