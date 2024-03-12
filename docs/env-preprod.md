## Environment: Pre-Production Testnet

Usage: Testing release candidates and mainnet releases. Forks at approximately same time as mainnet (within an epoch of each other).

Long running. Since this parallels mainnet, if a bug occurs here, it needs fixed properly and can not be respun.

Upgrade Strategy:

- Release Candidates - 1/3 of nodes
- Official Releases - 2/3 of nodes
- Hard forks - all nodes
- Community requested to only deploy release candidates and official releases

Changes Requested by: Release Squad Lead

Approvals Required: SRE Tribe Lead, Cardano Head of Engineering, Cardano Head of Architecture, CF Representative

Responsible: IOG SRE

Accountable: Head of SRE/Release Squad Lead

Consulted: SPOs, IOG Tribes

Informed: Cardano Core Tribe, COO, Director of Engineering, VP Community

#### Configuration files

Compatible with cardano-node release [8.9.0](https://github.com/IntersectMBO/cardano-node/releases/tag/8.9.0)

- [Node Config](environments/preprod/config.json)
- [DB Sync Config](environments/preprod/db-sync-config.json)
- [Submit API Config](environments/preprod/submit-api-config.json)
- [Node Topology](environments/preprod/topology.json)
- [Byron Genesis](environments/preprod/byron-genesis.json)
- [Shelley Genesis](environments/preprod/shelley-genesis.json)
- [Alonzo Genesis](environments/preprod/alonzo-genesis.json)
- [Conway Genesis](environments/preprod/conway-genesis.json)
