## Environment: Preview Testnet

Usage: Testing release candidates and mainnet releases. Leads mainnet hard forks by at least 4 weeks.

Ideally stays long running. Only if an issue is found after it forks that's breaking should it be respun.

Epoch length of 1 day. Development flags allowed in configuration files.

Upgrade Strategy:

- Release Candidates - 1/3 of nodes
- Official Releases - 2/3 of nodes
- Hard forks - all nodes
- Community requested to only deploy release candidates and official releases

Changes Requested by: Release Squad Lead

Approvals Required: SRE Tribe Lead, Cardano Head of Engineering, Cardano Head of Architecture

Responsible: IOG SRE

Accountable: Head of SRE/Release Squad Lead

Consulted: SPOs

Informed: Cardano Core Tribe, COO, Director of Engineering

#### Configuration files

Compatible with cardano-node release [8.9.2](https://github.com/IntersectMBO/cardano-node/releases/tag/8.9.2)

- [Node Config (Non-block-producers)](environments/preview/config.json)
- [Node Config (Block-producers)](environments/preview/config-bp.json)
- [DB Sync Config](environments/preview/db-sync-config.json)
- [Submit API Config](environments/preview/submit-api-config.json)
- [Node Topology](environments/preview/topology.json)
- [Byron Genesis](environments/preview/byron-genesis.json)
- [Shelley Genesis](environments/preview/shelley-genesis.json)
- [Alonzo Genesis](environments/preview/alonzo-genesis.json)
- [Conway Genesis](environments/preview/conway-genesis.json)
