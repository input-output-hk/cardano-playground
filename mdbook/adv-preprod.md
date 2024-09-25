## Advanced Configuration: Pre-Production Testnet

There is currently no pre-release version available for the pre-production
environment.

The latest version available is cardano-node release 9.2.1.

#### Configuration files

Compatible with cardano-node release [9.2.1](https://github.com/IntersectMBO/cardano-node/releases/tag/9.2.1)

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
