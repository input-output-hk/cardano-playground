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

Compatible with cardano-node release [10.4.1](https://github.com/IntersectMBO/cardano-node/releases/tag/10.4.1)

```
NOTE:
The non-block-producer node config has `PeerSharing` enabled by
default, so should not be used with block-producers.

Additionally, avoid connecting a block-producer not using p2p to a p2p
PeerSharing enabled relay as the block-producer's IP will be leaked.
```

- [Node Config (Non-block-producers -- see note above)](environments/preview/config.json)
- [Node Config (Block-producers)](environments/preview/config-bp.json)
- [DB Sync Config](environments/preview/db-sync-config.json)
- [Submit API Config](environments/preview/submit-api-config.json)
- [Node Topology](environments/preview/topology.json)
- [Node Topology (Genesis mode)](environments/preview/topology-genesis-mode.json)
- [Peer Snapshot](environments/preview/peer-snapshot.json)
- [Byron Genesis](environments/preview/byron-genesis.json)
- [Shelley Genesis](environments/preview/shelley-genesis.json)
- [Alonzo Genesis](environments/preview/alonzo-genesis.json)
- [Conway Genesis](environments/preview/conway-genesis.json)
- [Compiled guardrails script](environments/preview/guardrails-script.plutus)

#### UTXO-HD

Users migrating from a previous version of the node should read the [release
notes](https://github.com/IntersectMBO/cardano-node/releases/tag/10.4.1) and
the consensus [migration guide](https://ouroboros-consensus.cardano.intersectmbo.org/docs/for-developers/utxo-hd/migrating)
to properly configure the node and convert the database such that a replay from
genesis can be avoided.

#### Ouroboros Genesis Mode

For those preferring to use Genesis mode over bootstrap peers, the Genesis mode
topology file given above can be used in place of the default topology file.
The following requirements will also need to be met:

* The node config file will need to have `ConsensusMode` set to `GenesisMode`

* The peer snapshot file, provided above, will need to exist at the path
declared at `peerSnapshotFile` in the genesis mode topology file: an absolute
path, or a relative path with respect to the node binary directory

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Protocol Parameter Change proposals.

Guardrails script address: `addr_test1wrazf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqf68ll6`
Guardrails script UTxO: `f3f61635034140e6cec495a1c69ce85b22690e65ab9553ef408d524f58183649#0`
