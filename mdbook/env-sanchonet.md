## Environment: Sanchonet Testnet

Usage: Testing Conway era functionality.

The Sanchonet chain will be rolled back with each new node release for testing
new features and fixes. When respun on 2024-04-12 the chain will be restored
from slot 20044800.  Any Sanchonet chain participants, stakepools, integrators,
etc, will need to clear their chain state to re-sync from that point forward.

Epoch length of 1 day. Development flags allowed in configuration files.

Upgrade Strategy: Deploy all nodes with every upgrade request

Responsible: IOG SRE

Accountable: SRE Director

Consulted: Core Tech Head of Product

Informed: Cardano Core Tribe

#### Configuration files

Compatible with cardano-node pre-release [8.10.0-pre](https://github.com/IntersectMBO/cardano-node/releases/tag/8.10.0-pre)

- [Node Config (Non-block-producers)](environments/sanchonet/config.json)
- [Node Config (Block-producers)](environments/sanchonet/config-bp.json)
- [DB Sync Config](environments/sanchonet/db-sync-config.json)
- [Submit API Config](environments/sanchonet/submit-api-config.json)
- [Node Topology](environments/sanchonet/topology.json)
- [Byron Genesis](environments/sanchonet/byron-genesis.json)
- [Shelley Genesis](environments/sanchonet/shelley-genesis.json)
- [Alonzo Genesis](environments/sanchonet/alonzo-genesis.json)
- [Conway Genesis](environments/sanchonet/conway-genesis.json)
