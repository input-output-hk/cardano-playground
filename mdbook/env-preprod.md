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

Compatible with cardano-node release [10.6.2](https://github.com/IntersectMBO/cardano-node/releases/tag/10.6.2)

```
NOTE:
* The new tracing system is now default.  See additional notes below.

* There is no longer a need to maintain separate non-forger and forger config
files.  Node will now intelligently set PeerSharing, and a few other config
parameters based on forging status.

* The legacy non-p2p networking mode is no longer available.

* Avoid connecting PeerSharing enabled nodes to a block producer using
`InitiatorOnlyMode` as the block producer's IP will be leaked.
```

- [Node Config](environments/preprod/config.json)
- [Node Config Legacy](environments/preprod/config-legacy.json)
- [Tracer Config](environments/preprod/tracer-config.json)
- [DB Sync Config](environments/preprod/db-sync-config.json)
- [Submit API Config](environments/preprod/submit-api-config.json)
- [Node Topology](environments/preprod/topology.json)
- [Peer Snapshot](environments/preprod/peer-snapshot.json)
- [Byron Genesis](environments/preprod/byron-genesis.json)
- [Shelley Genesis](environments/preprod/shelley-genesis.json)
- [Alonzo Genesis](environments/preprod/alonzo-genesis.json)
- [Conway Genesis](environments/preprod/conway-genesis.json)
- [Compiled guardrails script](environments/preprod/guardrails-script.plutus)

#### New Tracing System

As of node `10.6.0` the new tracing system is default.  The legacy tracing
system is still available, with a legacy config provided above, but is
deprecated and will be removed in the near future.

See the [10.6.0 release notes](https://github.com/IntersectMBO/cardano-node/releases/tag/10.6.0)
for more information.

#### Ouroboros Genesis Mode

Ouroboros genesis mode is now the default consensus mode on preview and preprod
testnets starting with node `10.5.0`.  If needed, use of praos mode and the
bootstrap peers found in the above topology file can be reverted to by setting:

* Node config's `ConsensusMode` option to a value of `PraosMode`

#### UTXO-HD

Users migrating from a node version older than `10.4.1` should also read the [10.4.1 release
notes](https://github.com/IntersectMBO/cardano-node/releases/tag/10.4.1) and
the consensus [migration guide](https://ouroboros-consensus.cardano.intersectmbo.org/docs/for-developers/utxo-hd/migrating)
to properly configure the node and convert the database such that a replay from
genesis can be avoided.

#### Guardrails reference script UTxO

For convenience, the guardrails script has been put on a UTxO so that it can be used as reference script in
Treasury Withdrawal and Update Protocol Parameter proposals.

Guardrails script address: `addr_test1wrazf7es2yngqh8jzexpv8v99g88xvx0nz83le2cea755eqf68ll6`
Guardrails script UTxO: `9aabbac24d1e39cb3e677981c84998a4210bae8d56b0f60908eedb9f59efffc8#0`
