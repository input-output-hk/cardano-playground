# Debug block adoption

Two log events are emitted when a block a pool forged does not end up on the selected chain:

- `Forge.Loop.DidntAdoptBlock`, severity Error
- `ChainDB.AddBlockEvent.SwitchedToAFork`, severity Notice

Neither is an alert. Paging comes from the prometheus counters that back them. For a missed
adoption the rule lives in `flake/opentofu/grafana/alerts/cardano-node-forge.nix-import`:

```
(increase(cardano_node_metrics_Forge_didnt_adopt_counter[6h]) >= 3)
and
(increase(cardano_node_metrics_Forge_didnt_adopt_counter[6h])
   / clamp_min(increase(cardano_node_metrics_Forge_node_is_leader_counter[6h]), 1) > 0.25)
```

The second log event is backed by `forks_counter`.

The rule pages on a sustained *share* of leader slots failing, not on a count. A wedged forger
fails close to all of them, while ordinary tiebreak losses sit near 2.5% at an
`activeSlotsCoeff` of 0.05. That means a single missed adoption is expected and does not page.

The distinction matters throughout this doc, because those two log events describe the same
underlying loss, and only the first is counted by the rule above.

Those two events are usually read as separate problems. They are not. In most cases they are
two faces of the same loss, and which one appears is decided by local forge latency rather
than by anything about the block. Counting the missed adoption event alone therefore sees only
part of the real orphan rate.

This doc covers what the two events mean, the chain order rule that decides the loss, the
two root causes, and how to triage. For pools that are not forging at all, see
`debug-chain-quality.md` instead.

## The rule that decides the loss

Both events come from ChainDB chain selection comparing a candidate against the current
selection. The Praos chain order lives in
`ouroboros-consensus-protocol/src/ouroboros-consensus-protocol/Ouroboros/Consensus/Protocol/Praos/Common.hs`,
in `comparePraos`. In order:

1. Higher `blockNo` wins. A longer chain always beats a shorter one.
2. If both blocks have the same slot and the same issuer, the higher opcert issue number
   wins. This is the case where a pool restarted with a rotated cert.
3. Otherwise, if the VRF tiebreak is armed, the lower VRF value wins.
4. If the VRF tiebreak is not armed, neither is preferred, so the incumbent stays. First
   block to be selected keeps the chain.

Whether the VRF tiebreak is armed is an era level choice, set in
`ouroboros-consensus-cardano/src/shelley/Ouroboros/Consensus/Shelley/Ledger/Config.hs`:

- `UnrestrictedVRFTiebreaker` before Conway, always armed.
- `RestrictedVRFTiebreaker 5` from Conway onward, armed only when the two slots differ by
  at most 5.

The consequence that matters for triage: when the VRF tiebreak is armed, the outcome is
deterministic and completely independent of arrival order. The block with the lower VRF
wins no matter who got there first.

## Event 1, DidntAdoptBlock

Sequence in the logs, all within a few ms:

```
Forge.Loop.Call                              name=forge event=End
ChainDB.AddBlockEvent.TrySwitchToAFork
ChainDB.AddBlockEvent.StoreButDontChange
Forge.Loop.DidntAdoptBlock
```

Meaning: by the time our freshly forged block reached chain selection, a competing block
was already selected, and ours lost the comparison. The block is stored but never becomes
the tip. This is the event behind `Forge_didnt_adopt_counter`, so this is the one the paging
rule is built on, though only a sustained share of them will trip it.

### Which causes warrant a restart

A restart fixes exactly one of the causes below, so confirm which one before acting. This is
why the rule pages on a sustained share rather than on any single miss: the common cause is
benign and a restart does nothing for it.

`DidntAdoptBlock` is a catch all. It fires whenever the ChainDB add returns a tip that is not
our block and the block is not in the invalid set, see `addBlockToChainDB` in
`ouroboros-consensus-diffusion/src/ouroboros-consensus-diffusion/Ouroboros/Consensus/NodeKernel/Forge.hs`.
Distinct situations reach it:

- Lost the tiebreak at equal `blockNo`. Benign and expected, a restart changes nothing. This
  is the common case and the rest of this doc is about it.
- Chain selection picked a strictly longer chain, so our block was at a lower `blockNo`. The
  node was behind when it forged. Investigate sync health rather than restarting blind.
- `IgnoreBlockOlderThanImmTip`, our block was not newer than the immutable tip. The node
  forged on a chain more than k blocks behind, which is genuinely broken and needs
  intervention.
- `FailedToAddBlock`, the add never completed, so the block was never compared at all. The
  reasons in the source are `Failed to add block synchronously` and `Queue flushed`, both
  meaning the ChainDB add path or its background thread is not healthy. This is the one case
  a restart addresses.
- `IgnoreBlockAlreadyInVolatileDB`, the block was already present so the tip did not change.

A block that is invalid according to the ledger does not appear here at all. It traces as
`TraceForgedInvalidBlock` instead, which also drops the offending transactions from the
mempool, and it indicates a mempool versus ledger inconsistency rather than a chain selection
outcome.

Rule of thumb: isolated events that correlate with load peaks are tiebreak losses. Repeated
events, or events in consecutive leader slots, point at one of the pathological cases and are
worth investigating before restarting.

Note that the two pathological cases stall the tip, so on a pool with too few leader slots for
the ratio to trip, `cardano_node_blockheight_unchanged` and `cardano_node_block_divergence`
are what actually catch them. Neither depends on leader rate.

## Event 2, SwitchedToAFork

Meaning: a chain was already selected, then a better candidate arrived and the node rolled
back to it. The payload carries everything needed to attribute the loss:

```json
{
  "ns": "ChainDB.AddBlockEvent.SwitchedToAFork",
  "data": {
    "newSuffixSelectView": { "blockNo": 0, "slotNo": 0, "issuerHash": "...", "tieBreakVRF": "...", "issueNo": 0 },
    "oldSuffixSelectView": { "blockNo": 0, "slotNo": 0, "issuerHash": "...", "tieBreakVRF": "...", "issueNo": 0 },
    "reason": { "reason": "VRFTiebreak" }
  }
}
```

Important: this event also fires for battles between third party pools that the node merely
observes. It is not by itself evidence that our block was orphaned. To find our own
orphans, filter on `oldSuffixSelectView.issuerHash` matching our pool's issuer hash.

`forks_counter` tracks this event one for one, but it inherits the same attribution problem,
so it counts third party battles as well as our own losses. That makes it a poor direct
paging signal for our orphan rate, and attribution has to happen at the log level.

## Why the two are the same loss

Take a pool that loses a tiebreak. Two orderings are possible:

- The competitor reaches our ChainDB first. We never adopt ours. Result is
  `DidntAdoptBlock`, and the missed adoption counter increments.
- Our block reaches our ChainDB first. We adopt it, then the competitor arrives and wins
  the tiebreak. Result is `SwitchedToAFork`, and the missed adoption counter does not move.

Same comparison, same loser, different event. The only thing that moved is whether local
forge latency beat the competitor's diffusion time.

Two practical conclusions:

1. The missed adoption counter alone sees only the subset where the node was slow to chain
   selection, which biases the sample toward high load windows and can hide most of the real
   orphan rate. To measure the true rate, pair it with `SwitchedToAFork` filtered to our own
   issuer hash.
2. Do not expect reducing forge latency to save blocks. When the VRF tiebreak is armed it
   mostly converts `DidntAdoptBlock` into `SwitchedToAFork`, which moves the loss out of the
   counter without keeping the block. Forge latency is still worth reducing, for the reason in
   the next section.

## Root cause 1, same slot collisions

This is inherent to Praos and independent of load. Each pool runs a private local lottery.
For every slot it evaluates its own VRF and checks

```
VRF(slot, epochNonce) < threshold(sigma)     where   P(leader) = 1 - (1-f)^sigma
```

There is no coordination and no shared schedule, so nothing stops two pools from both
drawing a winning ticket in the same slot. Leader assignments are not mutually exclusive.

Because exponents add, `P(no leader at all) = (1-f)^sum(sigma) = 1-f` exactly, independent
of how stake is split. That is why an `activeSlotsCoeff` of 0.05 yields about 5% slot
occupancy whether the network has 4 pools or 400. It is a property of the aggregate and
says nothing about collisions.

The privacy is the point. A published mutually exclusive schedule would tell an adversary
exactly which pool to eclipse or DoS ahead of each slot. Praos accepts occasional
collisions and settles them with the VRF tiebreak.

To get the expected collision rate for a given network, feed the per pool block counts or
stake weights into this. Adjust `f` to the network's `activeSlotsCoeff`:

```awk
# usage: printf '%s\n' $COUNT_PER_POOL... | awk -f collisions.awk
BEGIN{ f=0.05; lnq=log(1-f) }
{ c[n++]=$1; tot+=$1 }
END{
  P0=1; S=0
  for(i=0;i<n;i++){ s=c[i]/tot; x=exp(s*lnq); xs[i]=x; P0*=x }
  for(i=0;i<n;i++) S += (1/xs[i] - 1)
  P1=P0*S; P2=1-P0-P1
  printf "pools=%d f=%.3f\n", n, f
  printf "P(0)=%.5f  P(1)=%.5f  P(>=2)=%.5f\n", P0, P1, P2
  printf "multi-leader as %% of non-empty slots: %.2f%%\n", 100*P2/(1-P0)
}
```

For a fairly concentrated network at `f` of 0.05, expect roughly 2% of non empty slots to
have more than one leader. A pool holding relative stake sigma sees another leader in its
own slot with probability `1 - (1-f)^(1-sigma)`, so a large pool collides more often in
absolute terms simply because it is leader more often. Roughly half of those collisions
are losses. This is a floor that cannot be tuned away by operators.

## Root cause 2, stale parent height battles

This one is load driven and is the part worth acting on.

The forge loop evaluates leadership at the start of the slot and calls `get-block-context`
immediately, which commits the parent. If the previous block has not arrived yet at that
instant, the node builds on an older parent and mints a block at the same height as the one
still in flight. Both then compare at equal `blockNo`, and the VRF tiebreak decides.

So the trigger is not our forge time, it is the previous block arriving after our slot
already began. Two things push blocks past that boundary, and load drives both:

- Forge time on the producing node. Block construction cost scales with mempool depth and
  block size, so under load it can consume a large fraction of a slot before the block is
  even published.
- Diffusion time. A block must be fully received and validated at each hop before being
  forwarded, so a producer to relay to relay to producer path multiplies. Larger blocks
  make every hop slower.

The feedback loop is worth spelling out: our own forge delay does not decide our own
tiebreaks, but it does delay when other producers see our block, which creates stale parent
battles for them. Reducing forge latency is a network wide improvement, not a local one.

## Triage

Replace `$ENV`, `$BP_NAME`, `$SLOT` and `$OUR_ISSUER` as appropriate. Sample a log line
before parsing, since JSON versus human readable format is a per host tracer choice and can
change on redeploy.

Find the events and confirm which of the two each one is:

```
{environment="$ENV", instance="$BP_NAME"} |= "DidntAdoptBlock"
{environment="$ENV", instance="$BP_NAME"} |= "SwitchedToAFork"
```

Attribute `SwitchedToAFork` to our pool, and read the slot distance and reason. Slot
distance 0 means a same slot collision, anything else means a height battle:

```
jq -rc 'select(.data.oldSuffixSelectView.issuerHash|startswith("$OUR_ISSUER"))
        | {at, oldSlot:.data.oldSuffixSelectView.slotNo,
           newSlot:.data.newSuffixSelectView.slotNo,
           slotDist:(.data.newSuffixSelectView.slotNo - .data.oldSuffixSelectView.slotNo),
           reason:.data.reason.reason}'
```

Pull the whole forge span for one slot to see where the time went. The span tracer emits
`Call` events carrying `name`, `event` and `duration`, so the breakdown of the forge loop is
directly readable:

```
{environment="$ENV", instance="$BP_NAME"} |= "$SLOT" |= "\"event\":\"End\""
```

Only the leios prototype node emits these spans at present. On other node builds this query
returns nothing and there is no equivalent per stage forge timing breakdown, so fall back to
`forgedSlotLast_int` plus the gap between `Forge.Loop.NodeIsLeader` and
`Forge.Loop.ForgedBlock` timestamps for a coarse total.

Look at the chain selection window around the event to identify what beat the block, and
when it arrived:

```
{environment="$ENV", instance="$BP_NAME"} |~ "AddedToCurrentChain|TrySwitchToAFork|StoreButDontChange"
```

Measure how late blocks are arriving, which is the direct test for root cause 2. Take the
`at` timestamp of each `AddedToCurrentChain`, subtract the wall clock time of
`newSuffixSelectView.slotNo`, and look at the distribution. Derive slot wall clock from the
shelley genesis `systemStart` and `slotLength`. A healthy idle network should sit well under
a slot. If the p90 approaches or exceeds one slot length, stale parent battles are expected.

Useful metrics, `cardano_node_metrics_` prefix:

- `Forge_didnt_adopt_counter` for event 1 and `forks_counter` for event 2. Both are
  cumulative counters, and only the first is specific to our own pool.
- `Forge_node_is_leader_counter`, `Forge_forged_counter` and `Forge_adopted_counter`. Leader
  equal to forged equal to adopted means the forge path itself is healthy.
- `blockfetchclient_blockdelay_real` and `_blocksize_int` for arrival delay and block size.
- `txsInMempool_int` and `mempoolBytes_int` to correlate with load.
- `instance:node_cpu_utilisation:rate5m`, `node_load1` and `rts_gc_gc_wall_ms` to rule out
  resource exhaustion. Forge cost that scales with mempool depth looks nothing like CPU
  saturation, so check before assuming the host is undersized.

## Gotchas

Losing blocks are systematically under observable from a single node. BlockFetch will not
download a block whose header already loses the tiebreak, so the node normally never stores
the loser. Counting collisions from `AddedBlockToVolatileDB` therefore gives a floor well
below the true rate, not the rate itself.

Any deployment that recycles the node service on a timer resets cumulative counters. Alert
rules should use counter increase rather than absolute value, and expect dashboards showing
lifetime totals to drop to zero on the recycle interval.

At default severities there are no `ChainSync.*` or `BlockFetch.*` traces, so block transfer
is only observable indirectly through `ChainDB.AddBlockEvent.*` on the receiver and
`Forge.*` on the producer. Absence of a hash in the logs is not evidence that no transfer
was attempted.

Some node builds emit two shapes on the same log stream, a bare `{"kind":...}` line and a
full envelope carrying `at`, `ns`, `data`, `sev` and `host`. Filter on `"ns":` to keep one
copy, otherwise every count is doubled.

Chain selection may carry extra weight terms beyond Praos, for example a Peras weight boost
surfaced as `weightBoost` in the select view. Confirm it is zero before reasoning about a
loss as plain Praos, since a nonzero boost changes the comparison ahead of the VRF tiebreak.
