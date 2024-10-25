## Advanced Configuration: Sanchonet Testnet

Users wanting to test a cardano-node pre-release version on the sanchonet
environment may obtain compatible configuration files below.

NOTE: When respun on 2024-10-21 the chain will be restored from slot 33782400.
Any Sanchonet chain participants, stakepools, integrators, etc, will need to
clear their chain state to re-sync from that point forward.

#### Configuration files

Compatible with cardano-node pre-release [10.1.1-pre](https://github.com/IntersectMBO/cardano-node/releases/tag/10.1.1-pre)

```
NOTE:
The non-block-producer node config has `PeerSharing` enabled by
default, so should not be used with block-producers.

Additionally, avoid connecting a block-producer not using p2p to a p2p
PeerSharing enabled relay as the block-producer's IP will be leaked.
```

- [Node Config (Non-block-producers -- see note above)](environments-pre/sanchonet/config.json)
- [Node Config (Block-producers)](environments-pre/sanchonet/config-bp.json)
- [DB Sync Config](environments-pre/sanchonet/db-sync-config.json)
- [Submit API Config](environments-pre/sanchonet/submit-api-config.json)
- [Node Topology](environments-pre/sanchonet/topology.json)
- [Byron Genesis](environments-pre/sanchonet/byron-genesis.json)
- [Shelley Genesis](environments-pre/sanchonet/shelley-genesis.json)
- [Alonzo Genesis](environments-pre/sanchonet/alonzo-genesis.json)
- [Conway Genesis](environments-pre/sanchonet/conway-genesis.json)
- [Compiled guardrails script](environments-pre/sanchonet/guardrails-script.plutus)
