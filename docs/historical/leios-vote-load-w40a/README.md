# Leios vote load test — prototype w40a

A load test run on 2026-10-09 against the leios environment: 750 synthetic pools voting
from ten `leiosred*-bp-*` block producers carrying 76 BLS keys each, against the 900-pool
CIP-0164 committee cap. Vote volume rose roughly 67x.

Read [`findings.md`](findings.md). It states what moved, what did not, and how strong the
evidence is for each, using an explicit classification: real signal, within noise,
confounded, invalid comparator, null result.

## Summary

| | verdict |
|---|---|
| Relay bandwidth | within noise, at both 5-minute and 1-second resolution |
| Relay node CPU | real signal, x1.42 |
| EB announcement lateness | real signal, 0.00-1.33% unloaded to 1.32 / 3.86 / 4.05% loaded |
| Certified EBs per forged EB | real signal, 33.3-46.7% unloaded to 26.3 / 28.6 / 16.0% loaded |
| Mean vote tally | invalid comparator under this load, see findings |

The certification result was not expected: the synthetic seats hold negligible stake and
should have added vote volume at zero weight. Two mechanisms fit the evidence and the data
does not distinguish them, see the certification section.

## Scope

Every number here is specific to **Leios prototype w40a** — relays on the governor-patched
variant, all other hosts on plain `node-leios`. Nothing in the test separates behaviour
specific to w40a from behaviour intrinsic to Leios, so treat the findings as scoped to this
build until reproduced on another.

## Contents

```
findings.md          the analysis
charts/              three rendered PNGs, referenced from findings.md
stats-summary.txt    derived statistics from the 1-second archive
mimir-windows.tsv    per-window Mimir metrics, tab separated
scripts/             collection, upload and rebuild scripts
data-1s/             raw archives, gitignored, see below
data-1s-wide/        raw archives, gitignored, see below
```

`scripts/` holds what produced the data and the documents: `collect-window.sh` for Mimir
metrics, `pull-1s.sh` and `pull-wide.sh` + `pull-wide-remote.sh` for netdata, and
`build-artifact.sh` with its CSS and page fragments for regenerating the HTML rendering.

## Raw data

The per-second netdata archives are ~200 MB, too large to commit. They are **gitignored in
place** so that re-analysis and the S3 upload run inside the repo's devshell, where awscli2
and credentials already are:

```
data-1s/             interface bandwidth, 19 hosts, 5.3 MB          (gitignored)
data-1s-wide/        CPU, memory, disk, TCP, PSI, per-process and   (gitignored)
                     the full network chart family. 19 hosts,
                     ~100 charts and ~210 dimensions each,
                     77.8M rows, 196 MB
```

A clone will not have them. They are kept in S3:

```
s3://cardano-playground-public/leios/vote-load-w40a-2026-10-09/
```

`MANIFEST.txt` lists size and sha256 for all 38 archive files, with paths relative to this
directory, so a download can be verified against it. To re-upload after adding a window:

```sh
./scripts/upload-archives.sh              # dry run
DRY_RUN=0 ./scripts/upload-archives.sh
```

Each archive directory carries its own README with the schema, per-chart-family units and
reading recipes. Units are **not** uniform across the wide archive — kilobits/s, packets/s,
percent, KiB/s, milliseconds and counts all appear — and neither is the sample interval:
most charts are 1-second, PSI is 2-second, `system.load` is 5-second.

This data cannot be regenerated. netdata's 1-second tier expires after roughly 96 hours and
Mimir never stored anything finer than a 5-minute average, so the windows from 2026-10-09
exist only in these archives.
## Why the raw data matters

Mimir's `rate5m` recording rules are exact for means and totals but capture only **6-15% of
the true peak** on this traffic, which is extremely bursty: median per-relay egress is under
2 Mbit/s against 1-second peaks reaching 585 Mbit/s. Moving to a 1-minute rate via `irate()`
on the raw counters recovers about 1.5x more peak and still reaches only 10-18%. The limit
is the 60-second scrape, not the averaging window, so no PromQL expression recovers it. Any
future question about burst behaviour on this cluster needs each host's local netdata on
port 19999 rather than Mimir.

## Related

A Grafana dashboard built for this test, **Cardano Leios - Vote Load Test**, uid
`cardano-leios-vote-load`, is in `flake/opentofu/grafana/dashboards/`.
