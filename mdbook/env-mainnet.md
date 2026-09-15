## Environment: Production (Mainnet)

Usage: Live Production. Only gets official mainnet releases.

Upgrade Strategy:

- Official Releases - Deploy 1 pool and it's relays every 24 hours
- Community requested to only deploy official releases

Changes Requested by: Release Squad Lead

Approvals Required: SRE Tribe Lead, IOG Executive Team, CF Executive Team

Responsible: IOG SRE
Accountable: Head of SRE/Release Squad Lead

Consulted: SPOs, IOG Tribes, IOG Executive Team

Informed: Cardano Core Tribe, COO, IOG Director of Engineering, IOG VP Community

#### Configuration files

Compatible with cardano-node release [11.1.1](https://github.com/IntersectMBO/cardano-node/releases/tag/11.1.1)

```
NOTE:
* Legacy tracing system is no longer available.

* Avoid connecting PeerSharing enabled nodes to a block producer using
`InitiatorOnlyMode` as the block producer's IP will be leaked.
```

- [Node Config](environments/mainnet/config.json)
- [Tracer Config](environments/mainnet/tracer-config.json)
- [DB Sync Config](environments/mainnet/db-sync-config.json)
- [Submit API Config](environments/mainnet/submit-api-config.json)
- [Node Topology](environments/mainnet/topology.json)
- [Node Topology (Non-bootstrap-peers)](environments/mainnet/topology-non-bootstrap-peers.json)
- [Peer Snapshot](environments/mainnet/peer-snapshot.json)
- [Checkpoints](environments/mainnet/checkpoints.json)
- [Byron Genesis](environments/mainnet/byron-genesis.json)
- [Shelley Genesis](environments/mainnet/shelley-genesis.json)
- [Alonzo Genesis](environments/mainnet/alonzo-genesis.json)
- [Conway Genesis](environments/mainnet/conway-genesis.json)
- [Compiled guardrails script](environments/mainnet/guardrails-script.plutus)

#### Ouroboros Genesis Mode

Ouroboros genesis mode is set as the default consensus mode in the node config
file provided above.  If needed, use of praos mode and the bootstrap peers
found in the above topology file can be reverted to by setting:

* Node config's `ConsensusMode` option to a value of `PraosMode`

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Protocol Parameter Change proposals.

Guardrails script address: `addr1w8azf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqjjnrsl`
Guardrails script UTxO: `dc06746a898fd230f164f47a3d749348b65655b8fb388ff275f54d62891653e2#0`
