## Advanced Configuration: Pre-Production Testnet

Users wanting to test a cardano-node pre-release version on the pre-production
environment may obtain compatible configuration files below.

The latest version available is cardano-node pre-release `10.1.0-pre`.

#### Configuration files

Compatible with cardano-node release [10.1.0-pre](https://github.com/IntersectMBO/cardano-node/releases/tag/10.1.0-pre)

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
- [Byron Genesis](environments-pre/preprod/byron-genesis.json)
- [Shelley Genesis](environments-pre/preprod/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/preprod/alonzo-genesis.json)
- [Conway Genesis](environments-pre/preprod/conway-genesis.json)
- [Compiled guardrails script](environments-pre/preprod/guardrails-script.plutus)
