# Leios vote load test — prototype w40a

A load test run on 2026-10-09 against the leios environment: 750 synthetic pools voting
from ten `leiosred*-bp-*` block producers carrying 76 BLS keys each, against the 900-pool
CIP-0164 committee cap.

The headline figure for the network is **15x**, the rate at which each node actually has to
receive and process vote records. Our own fleet's casting rate rose 67x, but that is a
statement about our share of the committee — our block producers went from 13 voting keys
to 763 — rather than about network load.

Read [`findings.md`](findings.md). It states what moved, what did not, and how strong the
evidence is for each, using an explicit classification: real signal, within noise,
confounded, invalid comparator, null result.

## Summary

Unloaded is the two pre-load on-hours of 10-09; loaded spans the 29 on-hours through
10-12 00:00. Only on-hours are comparable, because the generator runs a one-hour duty cycle.

| | verdict |
|---|---|
| Relay bandwidth | within noise, at both 5-minute and 1-second resolution |
| Relay node CPU, mean cores | real signal, 0.313-0.400 unloaded to 0.50-0.64 loaded |
| EB announcement lateness | real signal, 0.00-1.33% unloaded to 2.8-6.1% loaded |
| Certified EBs per forged EB | real signal, 38.1% unloaded to 31.9% loaded, p = 0.012 |
| Declines per 1000 votes | improved ~25x, 87-163 unloaded to 3.0-7.4 loaded |
| Mean vote tally | invalid comparator under this load, see findings |

The certification result was not expected: the synthetic seats hold negligible stake and
should have added vote volume at zero weight. Two mechanisms fit the evidence and the data
does not distinguish them, see the certification section.

Seats were later cut to ~600 to see whether either cost eased.
[`followup-600-seats.md`](followup-600-seats.md) has that comparison: relay CPU fell 13%,
lateness did not move, and the certification comparison is confounded by a community load
test that was running across the change.

## Scope

Every number here is specific to **Leios prototype w40a** — relays on the governor-patched
variant, all other hosts on plain `node-leios`. Nothing in the test separates behaviour
specific to w40a from behaviour intrinsic to Leios, so treat the findings as scoped to this
build until reproduced on another.

## Contents

```
findings.md          the analysis
followup-600-seats.md    follow-up: seats cut ~900 -> ~600 on 2026-10-15
followup-600-seats.tsv   its per-hour series, tab separated
charts/              three rendered PNGs, referenced from findings.md
stats-summary.txt    derived statistics from the 1-second archive
mimir-windows.tsv    per-window Mimir metrics, tab separated
MANIFEST.txt         apparent size and sha256 for all 76 archive files
scripts/             collection, upload and rebuild scripts
data-1s/             raw archives, gitignored, see below
data-1s-wide/        raw archives, gitignored, see below
data-weekend/        raw archives, gitignored, see below
data-weekend-wide/   raw archives, gitignored, see below
```

`scripts/` holds what produced the data and the documents:

```
collect-window.sh         Mimir metrics per window
pull-1s.sh                netdata interface bandwidth, the six 10-09 windows
pull-wide.sh              the wide chart set, same windows
pull-wide-remote.sh         the half that runs on the host
pull-weekend.sh           netdata interface bandwidth, the 58-hour span
pull-wide-weekend.sh      the wide chart set over the 58-hour span
pull-wide-weekend-remote.sh the half that runs on the host
make-manifest.sh          regenerates the top-level MANIFEST.txt
verify-wide-weekend.sh    integrity pass over data-weekend-wide, writes its MANIFEST.txt
fleet-tables.sh           recomputes the fleet egress/ingress tables
make-chart-03.sh          regenerates charts/03 from the archives
upload-archives.sh        pushes the archives to S3
check-public-access.sh    confirms the S3 prefix is not world-readable
build-artifact.sh         renders findings.md to HTML, with findings.css
                          and the artifact-*.html fragments
```

## Raw data

The per-second netdata archives total **3.0 GB across 76 files**, too large to commit. They
are **gitignored in place** so that re-analysis and the S3 upload run inside the repo's
devshell, where awscli2 and credentials already are. Sizes below are apparent; these
directories sit on zfs, so `du` reports roughly half.

```
data-1s/             interface bandwidth, six 1-hour windows on    (gitignored)
                     10-09. 19 hosts, 5.1 MB
data-1s-wide/        CPU, memory, disk, TCP, PSI, per-process and   (gitignored)
                     the full network chart family, same six
                     windows. 19 hosts, ~100 charts and ~210
                     dimensions each, 77.1M rows, 291 MB
data-weekend/        interface bandwidth, 58 continuous hours from  (gitignored)
                     10-09 14:00 to 10-12 00:00. 19 hosts,
                     208,801 rows each, 48 MB
data-weekend-wide/   the wide chart set over those same 58 hours.   (gitignored)
                     19 hosts, 35.7M-55.7M rows each, 2.7 GB
```

A clone will not have them. They are kept in S3:

```
s3://cardano-playground-public/leios/vote-load-w40a-2026-10-09/
```

`MANIFEST.txt` lists apparent size and full sha256 for all 76 archive files, with paths
relative to this directory. Sizes are apparent rather than `du`, which reports the
compressed on-disk size on zfs and would not match a downloaded copy. Every file is
gzip-tested before being listed, so the manifest cannot describe a truncated archive as
good. To check a download:

```sh
awk '!/^#|^file/ {print $3"  "$1}' MANIFEST.txt | sha256sum -c
```

`data-weekend-wide/MANIFEST.txt` additionally records row, chart and dimension counts and
the time span per host. Regenerate either with `./scripts/make-manifest.sh` or
`./scripts/verify-wide-weekend.sh`. To re-upload after adding a window:

```sh
./scripts/upload-archives.sh              # dry run
DRY_RUN=0 ./scripts/upload-archives.sh
```

Each archive directory carries its own README with the schema, per-chart-family units and
reading recipes. Units are **not** uniform across the wide archive — kilobits/s, packets/s,
percent, KiB/s, milliseconds and counts all appear — and neither is the sample interval:
most charts are 1-second, PSI is 2-second, `system.load` is 5-second.

Mimir never stored anything finer than a 5-minute average, so this resolution exists
nowhere else once netdata ages it out.

**How long the source stays re-pullable.** The hosts run netdata 2.8.4 with no `[db]`
section in `/etc/netdata/netdata.conf`, so the upstream defaults apply: tier 0 keeps
1-second samples for a requested 14 days, bounded in practice by disk. Measured on
2026-10-12, actual tier-0 retention ranged from **8d22h on `leios1-rel-a-1` to 21d8h on
`leiosred1-bp-a-1`**, with most hosts at or above the 14-day request.

There is no urgency here: the 10-09 windows remain re-pullable from the hosts until about
2026-10-18 even on the shortest-retention host. The archives still exist so the analysis is
reproducible after that date, and so re-analysis does not depend on live hosts.

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
