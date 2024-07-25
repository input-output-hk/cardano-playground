## Environment: Private Testnet

Usage: Testing Conway era functionality.

The Private chain will be spun up or respun as needed for short term testing.

Epoch length of 2 hours. Development flags allowed in configuration files.

Upgrade Strategy: Deploy all nodes with every upgrade request

Responsible: IOG SRE

Accountable: SRE Director

Consulted: Core Tech Head of Product

Informed: Cardano Core Tribe

#### Faucet

A faucet for the private testnet is available [here](https://faucet.private.play.dev.cardano.org/basic-faucet)


#### Configuration files

Compatible with cardano-node release [9.1.0](https://github.com/IntersectMBO/cardano-node/releases/tag/9.1.0)

```
NOTE:
The non-block-producer node config has `PeerSharing` enabled by
default, so should not be used with block-producers.

Additionally, avoid connecting a block-producer not using p2p to a p2p
PeerSharing enabled relay as the block-producer's IP will be leaked.
```

- [Node Config (Non-block-producers -- see note above)](environments/private/config.json)
- [Node Config (Block-producers)](environments/private/config-bp.json)
- [DB Sync Config](environments/private/db-sync-config.json)
- [Submit API Config](environments/private/submit-api-config.json)
- [Node Topology](environments/private/topology.json)
- [Byron Genesis](environments/private/byron-genesis.json)
- [Shelley Genesis](environments/private/shelley-genesis.json)
- [Alonzo Genesis](environments/private/alonzo-genesis.json)
- [Conway Genesis](environments/private/conway-genesis.json)
