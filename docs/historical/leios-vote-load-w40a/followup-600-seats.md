# Follow-up — committee seats cut from ~900 to ~600

**Date:** 2026-10-16. All times UTC. Analysis cut-off 18:48.
**Question:** did halving the synthetic vote load relieve either of the two costs
[`findings.md`](findings.md) attributed to it — EB announcement lateness and the
certification drop?

**Answer: no.** Lateness is unchanged, certification did not improve, and the certification
comparison is confounded badly enough that it should not be read as a seat effect in either
direction. The one measured cost that did fall is relay CPU.

## The change

On 2026-10-15 between 18:00 and 00:00, reported at ~19:00, the BLS key arrays on the ten
`leiosred*-bp-*` hosts went from 76 keys to 46. Our own voting keys went 761 → 462; with the
~140 non-fleet pools that is roughly 900 → 600 seats actually casting votes. Measured with

```promql
count(max_over_time(rate(leios_logmetrics_leios_votes_cast_total{environment="leios"}[10m])[2h:10m]) > 0)
```

which reads a steady 761 through 10-15 18:00 and a steady 462 from 10-16 00:00 onward, with
no drift across the 19 hours since. Fleet vote casting fell 24.85 → 16.85 per second, a
ratio of 0.678 against the 0.667 the seat counts predict.

Note what this does and does not change. The 750 synthetic pools stay registered, the chain
stays at the 900-pool CIP-0164 cap, and the dropped pools keep **silent, zero-stake seats**.
Removing keys reduces votes cast, not seats allocated or weight reachable. So there is no
weight-based mechanism by which this change should move certification at all — a point that
matters when reading the certification result below.

## Why the obvious before/after window does not work

A **community load test was running throughout**. What it did to the environment:

- **Our own generators stopped at ~10-14 22:00.** Fleet
  `rate(leios_logmetrics_txgen_submitted_total[5m])` runs 35–81 tx/s on on-hours through
  10-14 21:05, then 0.00 for every hour of 10-15 and 2.5–17.2 on 10-16.
- **The duty cycle ended at the same moment.** The last off-period is 10-14 21:20–22:00. From
  10-14 22:10 to the analysis cut-off, EB transaction throughput is continuous at 82–198 tx/s
  and the mempool never drains, holding 3,700–10,200 transactions around the clock. Under the
  duty cycle it emptied completely between runs: across the settled part of every off-hour —
  `:20` to `:50`, past the drain — the mempool holds a mean of 4 transactions and never more
  than 115.
- The community load therefore began **about 21 hours before the seat cut** and was **still
  running** at 18:48 on 10-16.

Two consequences for the design. First, the duty-cycle rule that governs every comparison in
`findings.md` — align on-hour to on-hour, offsets in even hours — is **moot** for anything
after 10-14 22:00, because there are no off-hours left to misalign with. Second, and this is
the trap, a "before" window reaching back past 10-14 22:00 straddles the boundary: 10-13
00:00 → 10-15 18:00 is 46 hours of duty-cycled, our-generator load plus 20 hours of
continuous community load. Comparing that mixture against the after window measures the
regime change, not the seat change.

The confounder does, however, hand back a cleaner design than the one it broke. There are
~21 hours of continuous community load at 900 seats and ~18 at 600, with our generators off
on both sides. Those are regime-matched, so that is the comparison used here.

| | span | h | regime | seats |
|---|---|---|---|---|
| **C** | 10-14 22:05 → 10-15 18:05 | 21 | continuous community load, our generators off | ~900 |
| **D** | 10-16 00:05 → 18:05 | 18 | continuous community load, our generators off | ~600 |

Windows are 1 hour, `:05`-anchored, the same convention as `findings.md`. The 10-15
18:00–00:00 crossover is excluded entirely, which also drops the 23:05–00:05 window
containing a 25-host restart wave.

## Instrument change: pool the three control BPs

`findings.md` counts certified and forged EBs from `leios1-bp-a-1` alone, which yields about
24 forged EBs per hour. At that rate the minimum detectable effect over these windows is
**8.9 points** — so the instrument could not have resolved a full reversal of the original
6.2-point drop even if one had occurred.

`LeiosBlockForged` and `LeiosBlockCertified` are both per-host and both scale with that
host's own EB production, so the three control BPs can be pooled. They are the right ones to
pool: config-pinned topology, one real key each, untouched by the key change. That triples
the counts to ~70 forged EBs per hour and brings the MDE to **5.1 points**, which is enough
to see an effect the size of the one being looked for.

Counts come from the indexed `kind` label, which matches one copy of each line and must
**not** be halved — unlike the line-filter form used in `findings.md`, which matches both the
raw and the alloy-decoded copy. The two agree: the `kind` form reproduces the 9 certified /
20 forged of the original `base_11` window exactly.

## Results

Classification follows `findings.md`: **real signal**, **within noise**, **confounded**,
**invalid comparator**, **null result**.

| Measure | C, ~900 seats | D, ~600 seats | Verdict |
|---|---|---|---|
| EB announce late, % | 2.65 pooled | 3.08 pooled | **Within noise** — no improvement |
| Certified per forged EB, % | 41.06 | 35.90 | **Confounded** — no improvement |
| Relay CPU, mean cores | 0.601 | 0.525 | **Real signal** — improved, p ≈ 0.0002 |
| Votes cast, fleet /s | 24.85 | 16.85 | the change itself, p < 1e-4 |
| Declines per 1000 votes | 3.8 | 8.4 | **Confounded** — denominator moved |

### EB announcement lateness — within noise, no improvement

| | pooled late % | per-hour mean (sd) | per-hour range |
|---|---|---|---|
| C, ~900 seats | 2.65 | 2.58 (1.50), n=21 | 0.16–5.71 |
| D, ~600 seats | 3.08 | 3.04 (1.79), n=18 | 0.03–7.99 |

Welch t = 0.87, p ≈ 0.39; Mann-Whitney p ≈ 0.37. The direction is *worse*, not better.

This negative result is firmer than the p-value alone suggests, because the comparison has
the power to see what was being looked for. The MDE across these windows is **1.47 points**,
and a return to the original unloaded band of 0.00–1.33% from 3.04% would be a move of
roughly 1.7 points. Lateness remains at the bottom of the 2.8–6.1% band the load test
measured, and the seat cut did not pull it out.

The ratio stays denominator-safe: announcement volume moved only 1.180 → 1.269/s and EB
forging is flat (23.3 vs 24.6 per hour on the control BPs, p = 0.51). One caveat — the host
count reporting both series fell from 29 to 27–28. Since this is a fleet-pooled ratio, a
missing host removes numerator and denominator together, but it is not exactly neutral.

Sensitivity: including the excluded 10-15 23:05–00:05 window raises D to 3.74%, which moves
the result further from improvement rather than toward it.

### Certification — confounded, and the window choice decides the answer

Pooled over the three control BPs:

| period | seats | certified / forged | ratio |
|---|---|---|---|
| duty-cycled on-hours, 10-13 00:00 → 10-14 22:00 | ~900 | 561 / 1662 | **33.75%** |
| continuous community load, pre-cut (C) | ~900 | 618 / 1505 | **41.06%** |
| continuous community load, post-cut (D) | ~600 | 481 / 1340 | **35.90%** |

Regime-matched C vs D is a 5.17-point drop, z = 2.83, **p = 0.0047**. It is not an artifact
of pooling: the per-hour ratios agree, Welch p = 0.021 and Mann-Whitney p = 0.013.

That arithmetic is sound and should still not be read as a seat effect. The first two rows
differ by **+7.3 points with seat count held constant** — larger than the 6.2 points the
original test attributed to the vote load, and larger than the 5.2 attributed here to the
cut. A metric that swings that far on a change in the *character* of the transaction load
cannot carry an attribution to seats across a window where the load character also changed.

The same instability shows up as window sensitivity. Taking the full 10-13 00:00 → 10-15
18:00 span as "before", as a reader would naturally do, gives −0.72 points and p = 0.66 — a
null. The two answers differ only in where the before-window starts.

What can be said: certification did not improve on any comparison tried. What cannot: that
the seat cut harmed it. The mechanism argument points the other way as well, since the
dropped seats carried no stake weight.

### Relay CPU — real signal, improved

Mean cores across the nine relays fell **0.601 → 0.525**, a 13% reduction, Welch
p < 0.0001 and Mann-Whitney p = 0.0002. This is the third of the three costs in
`findings.md`, where it was the clearest of them, and it is the one the seat cut relieved.

It is also understated rather than inflated: CPU fell while EB transaction throughput rose
15% and mempool depth rose 34%. Absolute values stay modest either way.

### Declines — confounded

Declines per 1000 votes cast went 3.8 → 8.4, and the raw rate went 0.096 → 0.141/s. Both
directions look like strain, and neither is interpretable here. The normalised figure has a
denominator that fell 32% by construction, and the raw figure is sensitive to restart churn,
which is higher in D. `findings.md` reports this measure improving ~25× under the original
load; nothing here revises that.

## Confounders

Every one of these sits in the after window and pushes toward *worse*, so the two null
results are not being propped up by a favourable comparison.

- **EB transaction throughput** 134.3 → 154.9 tx/s, +15%, p = 0.002.
- **Mempool depth** 5,352 → 7,155 transactions, +34%, p < 0.0001.
- **Node restarts** 2.0/h → 3.5/h, against the ~2.2/h the 12-hour `RuntimeMaxSec` timer
  produces across 26 hosts on its own. Included is a 25-host fleet-wide restart in the
  10-15 23:05–00:05 window — which is why that window shows a mean announcement age of 144
  seconds and 11.45% late, and why it is excluded.
- **`txgen_per_s` is not a usable confounder check** on this pair, contrary to how it is used
  throughout `findings.md`. Our generators are off on both sides, 1.0 vs 6.7 tx/s, so the
  metric reports neither window's real transaction load. Use
  `leios_logmetrics_diffusion_body_txs_total` and `cardano_node_metrics_txsInMempool_int`
  instead.

## What is too early to call

**Certification.** Significant arithmetic on an instrument that moves ±7 points on load
regime alone. Do not record a seat-attributable effect from it in either direction.

**Lateness.** Callable as a null, with the caveat that 18 hours against 21 is thin and that
both sides sit inside a community test whose intensity is drifting upward through the span —
EB throughput rises from 101 to 190 tx/s across C alone.

**The cheapest test that would settle both** is a period at 600 seats with the community load
finished and our own duty-cycled generators back on. That reproduces the exact regime of the
33.75% row and of the original unloaded baselines, which makes both comparisons like-for-like
and restores the off-hours that give lateness a 0.00–1.33% reference. Everything measured
here is inside someone else's experiment.

Keep the three-BP pooled certification count regardless. It costs nothing and
`leios1-bp-a-1` alone needs roughly 40 hours per side to resolve a 6-point effect.

## Method and data

Mimir and Loki through the Grafana datasource proxy, same sources as `findings.md`. Hourly
figures are `avg_over_time((expr)[3600s:60s])` evaluated at each window end; EB counts are
`sum(count_over_time({... kind="..."}[1h]))` as instant queries at the same instants. Loki's
`query_range` snaps step boundaries to multiples of the step and would have silently shifted
`:05`-anchored windows to `:00`, so the counts are collected one instant query per window
instead.

Significance tests: two-proportion z for pooled EB counts, Welch's t and Mann-Whitney U on
the per-hour series. Where both a pooled and a per-hour test are quoted they agree; where
only the pooled one is quoted the per-hour series is too overdispersed for it to stand
alone.

`followup-600-seats.tsv` holds the per-hour series behind every figure above — transaction
throughput, mempool depth, announcement volume and lateness, relay CPU, votes cast and
declined, and EB certified/forged counts both pooled and for `leios1-bp-a-1` alone — from
2026-10-12 01:05 to 2026-10-16 18:05.
