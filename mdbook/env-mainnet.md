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

Compatible with cardano-node release [10.5.1](https://github.com/IntersectMBO/cardano-node/releases/tag/10.5.1)

```
NOTE:
The non-block-producer node config has `PeerSharing` enabled by
default, so should not be used with block-producers.

Additionally, avoid connecting a block-producer not using p2p to a p2p
PeerSharing enabled relay as the block-producer's IP will be leaked.
```

- [Node Config (Non-block-producers -- see note above)](environments/mainnet/config.json)
- [Node Config (Block-producers)](environments/mainnet/config-bp.json)
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

For those preferring to use Genesis mode over bootstrap peers, the following
requirements will also need to be met:

* The node config file will need to have `ConsensusMode` set to `GenesisMode`

* To the topology file, a new key of `peerSnapshotFile` will need to be added
and set to the path of the peer snapshot file, provided above.  The declared
path can be absolute or relative with respect to the directory of the topology
file.

#### UTXO-HD

Users migrating from a node version older than `10.4.1` should also read the [10.4.1 release
notes](https://github.com/IntersectMBO/cardano-node/releases/tag/10.4.1) and
the consensus [migration guide](https://ouroboros-consensus.cardano.intersectmbo.org/docs/for-developers/utxo-hd/migrating)
to properly configure the node and convert the database such that a replay from
genesis can be avoided.

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Protocol Parameter Change proposals.

Guardrails script address: `addr1w8azf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqjjnrsl`
Guardrails script UTxO: `dc06746a898fd230f164f47a3d749348b65655b8fb388ff275f54d62891653e2#0`
