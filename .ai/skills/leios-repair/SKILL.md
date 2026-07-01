---
name: leios-repair
description: Diagnose and repair Leios cluster forks and stuck block producers — detect whether the network is forked (which nodes, what trigger), and reseed a forked/behind node's chain state from a healthy donor relay so it rejoins the main chain. Use when a Leios environment shows a fork, a BP stuck on its own tip, a node falling behind, or an endorser-block (EB) production stall. Requires on-host access via the cluster-ssh skill (SRE opens masters first).
---

# Repairing Leios forks & stuck nodes

Leios (the leios* environments) hits a recurring class of **non-self-healing forks**: a block
producer ends up on its own branch and cannot re-converge to the main chain on its own. Until the
upstream fix lands (ouroboros-leios issue #890 / PR #2073), **operator reseed is the remedy each
time**. This skill is the diagnose→fix playbook.

- **Access** is via the **`cluster-ssh`** skill (ControlMaster sockets + `/tmp/sshw`, `wush` for
  host-to-host bulk transfer). Read it first; this skill assumes `bash /tmp/sshw <host> '<cmd>'` works.
- **Telemetry** is via the **`monitoring-query`** skill (Loki/Mimir) — use it for the fleet-wide
  first look (block heights, EB counters, density) before going on-host.
- **Read-only by default.** The reseed steps here **mutate** a node — confirm with the SRE first
  (see *Mutation policy*).

> **Status & maintenance** (this skill tracks a moving target — keep it current):
> - *Last verified:* 2026-07-01, against the current Leios playground deploy.
> - *Reseed still required:* YES — forks are non-self-healing pre ouroboros-leios #890 / PR #2073.
>   When that fix + pin bump lands, re-test whether forks self-heal and **downgrade/retire the reseed
>   loop** here accordingly.
> - *Known-open behaviors:* the fork families in §4; EB-production stall (§1c). Add new triggers to §4
>   as they're found (name the trigger + a triage grep) and link the incident write-up.
> - *When the network upgrades or storage/paths/units change:* re-confirm §2 (storage layout), the
>   magic/socket/cli constants, and that `recover_bp.sh`'s assumptions still hold — update both files
>   together. Bump *Last verified* whenever you re-check against a new deploy.

Deployment specifics below (socket path, network magic, storage paths) are for the current Leios
playground deploy — **confirm them** if the deploy changed (`systemctl cat cardano-node`, `ls`).
Network magic = **164**; node socket = `/run/cardano-node/node.socket`; cli =
`/run/current-system/sw/bin/cardano-cli`. Hosts: `leios<N>-{bp,rel}-<az>-1` (+ dbsync/faucet/centrifuge
on leios1). Relays track the main chain; BPs (`-bp-`) forge.

## 1. Is it actually forked? (diagnose before touching anything)

A BP briefly **ahead** of the relays (it just forged) is normal and self-resolves. A **fork** is when
a node sits on a hash the main chain never adopts. Distinguish them:

**a) Tip vs relays, sampled over ~40s.** Healthy = BPs converge to the relay hash within a slot or
two. Fork = a BP's hash never appears on the main chain while relays advance on *other* hashes.
```sh
for h in leios1-rel-a-1 leios1-bp-a-1 leios2-bp-b-1 leios3-bp-c-1; do
  printf "%-14s " "$h"
  bash /tmp/sshw "$h" 'export CARDANO_NODE_SOCKET_PATH=/run/cardano-node/node.socket; \
    cardano-cli query tip --testnet-magic 164 2>/dev/null | grep -oE "\"block\": [0-9]+|[0-9a-f]{16}" | tr "\n" " "'; echo
done
# repeat a few times (sleep 8) — see whether BP hashes ever match the main chain
```

**b) Forger identity on each BP's own chain** (the decisive test). On a forked BP, recent
`AddedToCurrentChain` blocks are forged **only by itself** (one `issuerHash`); a healthy node adopts
**many foreign** forgers. This is a multi-operator net (~11 pools) — our 3 BPs are a subset.
```sh
bash /tmp/sshw leios3-bp-c-1 'journalctl -u cardano-node --no-pager -S "8 min ago" -o cat 2>/dev/null \
  | grep -a "\"kind\":\"AddedToCurrentChain\"" | grep -aoE "\"issuerHash\":\"[0-9a-f]{10}" | sort | uniq -c'
# only-own issuerHash + tip never matching main chain = SOLO FORK → reseed that BP.
```

**c) EB-production stall** (a *different* failure — NOT a fork). A BP can be on the main chain for RBs
yet stop forging **endorser blocks**. Compare the counter across BPs (Mimir / monitoring-query):
`cardano_node_metrics_Forge_endorser_block_total_count_counter{environment="leios",instance=~".*-bp-.*"}`
— a flat line while peers climb (~3 EB/hr/pool) = EB stall. **Do NOT reseed for this** (the RB chain
is fine); investigate the EB-forge path / restart as a last resort.

## 2. Storage layout (what gets reseeded)

Leios nodes use split storage:
- `/var/lib/cardano-node/db-leios` — RB/ledger chain DB (EBS).
- `/ephemeral/cardano-node/leios.db` (+ `-wal`/`-shm`) — Leios EB/vote DB (ephemeral disk).

Donor relays publish a combined snapshot at `/ephemeral/nginx-artifacts/leios.full.tar.zst`
(+ `.sha256`, `.meta.json`) — top-level `db-leios/` + `leios.db`. **Only `-rel-*-1` relays carry the
artifact** (check per group); it's an **hourly** ZFS snapshot.

## 3. Reseed a forked/behind node (`recover_bp.sh`)

`recover_bp.sh` (in this skill dir) does: stop node → `wush` the donor's artifact host-to-host →
verify sha → swap DBs (old → `*.fork-bak`, non-destructive) → restart. Works for BPs **and** dbsync
hosts (db-sync auto-reconnects and rolls forward; no Postgres reseed needed).

**Pick a donor** = a same-group relay on the main chain with a **fresh** artifact:
```sh
for r in leios1-rel-a-1 leios2-rel-b-1 leios3-rel-c-1; do printf "%-16s " "$r"; \
  bash /tmp/sshw "$r" 'ls --time-style=+%H:%M:%SZ -l /ephemeral/nginx-artifacts/leios.full.tar.zst 2>/dev/null | awk "{print \$6}"; \
    grep -oE "\"snapshot_created\":[^,]+" /ephemeral/nginx-artifacts/leios.full.tar.zst.meta.json 2>/dev/null'; echo; done
```

**Run it** (confirm with SRE first — this mutates the target):
```sh
bash .ai/skills/leios-repair/recover_bp.sh leios3-bp-c-1 leios3-rel-c-1   # <target> <donor-relay>
```
(The agent typically runs a copy from `/tmp`; keep it there or reference the skill path.)

**Reseed only the FORKED nodes; leave healthy ones alone.** If several BPs are forked, reseed each
from its group relay (sequential is safest; the script `pkill`s `wush` on the donor between runs).

**Verify convergence** — wait for the main chain to advance ~8 blocks and confirm every reseeded node
matches the relay tip hash, and is adopting **foreign** blocks again (§1b). Only then call it fixed.

### Whack-a-mole caveat
Taking BPs offline for reseed disturbs the small cluster's block propagation, which can tip the
**next** BP into the same fork (observed 2026-07-01: reseeding two BPs → the third forked). **Always
re-check ALL BPs after a reseed round**, not just the ones you reseeded.

## 4. Known fork/stall families (for triage & the consensus team)

All share the end-state (solo fork, non-self-healing, reseed required) but differ by trigger — name
the trigger in the incident:
- **EB-closure / data-availability wedge** — `LeiosBlockPointMissing` in the journal; RB selection
  blocked on a missing EB body (`StoreButDontChange` *caused by* the missing point). Triggers seen:
  size-0 EB offer, EB slot-identity mismatch, tx-closure never requested.
- **RB chain-selection non-convergence** (2026-07-01) — **zero** `LeiosBlockPointMissing`,
  `weightBoost`=0 everywhere; competing same-height blocks + each BP forges ahead on its own branch +
  self-favoring VRF tiebreak → `StoreButDontChange` on the main-chain blocks and never re-converges.
  `CompletedBlockFetch` present (it *does* fetch the main blocks; it just won't switch).
- **EB-production stall** — RBs fine, `Forge_endorser_block_total_count_counter` flat (§1c). Not a
  fork; reseed won't help.

Quick triage greps in the fork window (hosts are UTC):
```sh
bash /tmp/sshw <bp> 'journalctl -u cardano-node --no-pager -S "<start>" -U "<end>" -o cat 2>/dev/null \
  | grep -acE "LeiosBlockPointMissing"'   # >0 => closure wedge; 0 => chain-select family
```

## Mutation policy
Diagnosis (§1) is read-only — run freely. The reseed (§3) **stops, swaps DB, and restarts** a node:
**confirm with the SRE before running**, consistent with `cluster-ssh`. It is non-destructive (old
DB kept at `*.fork-bak`); once convergence is verified and stable, the `*.fork-bak` dirs can be
removed to reclaim space.

## Gotchas
- `density_real` is a **trailing average** — it lags a fixed fork/load window; check live per-BP
  forge counts before concluding "nothing is forging".
- SSM masters expire (`AI_SSH_PERSIST`, default 2h); `-O check` first, ask SRE to re-open if down.
- Forks do **not** self-heal pre-#2073 — expect recurrence; a reseed is a stopgap, not a fix.
- Don't reseed a node that's merely *ahead* of the relays (it just forged) — confirm a true fork (§1).
