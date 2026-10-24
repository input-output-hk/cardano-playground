#!/usr/bin/env bash
# Recompute the fleet egress and ingress tables in stats-summary.txt from data-1s/.
#
# Fleet statistics must be computed on the fleet series itself: sum the 9 relays at each
# second first, then take percentiles and max of those 3600 sums. Order matters for
# everything except the mean, which is linear and comes out the same either way. That is
# why a wrong ordering hides: the means still agree. For scale, a sum of per-host maxima
# gives 3419 Mbit/s in base_13 against a true fleet peak of 1776, because the relays do
# not peak in the same second.
#
# Prints both tables for comparison against the committed stats-summary.txt. The per-host
# and per-relay tables in that file are genuinely per-host and are unaffected.
set -uo pipefail
cd "$(dirname "$0")/.."
GZ="${GZIP:-$(command -v gzip || ls /nix/store/*gzip-1.14/bin/gzip 2>/dev/null | head -1)}"

# $6 is netdata 'sent' (egress, negative); $5 is 'received' (ingress).
table() {
  for f in data-1s/leios[123]-rel-*.csv.gz; do "$GZ" -cd "$f"; done | awk -F, -v fld="$1" '
    { v = $fld; if (v < 0) v = -v; s[$1","$4] += v/1000 }
    END{
      for (k in s) { split(k,a,","); w=a[1]; n[w]++; val[w][n[w]] = s[k]; tot[w] += s[k] }
      for (w in val) {
        c = n[w]; for (i=1;i<=c;i++) arr[i] = val[w][i]
        for (i=2;i<=c;i++) { x=arr[i]; j=i-1; while (j>0 && arr[j]>x) { arr[j+1]=arr[j]; j-- } arr[j+1]=x }
        m = tot[w]/c
        printf "%-10s%9.1f%10.1f%10.1f%10.1f%10.1f%10.1f\n", w, m,
          arr[int(c*0.50)], arr[int(c*0.95)], arr[int(c*0.99)], arr[c], arr[c]/m
      }
    }' | sort
}

echo "## Fleet total egress (sum of the 9 relays at each second)"
echo "window         mean       p50       p95       p99       max   pk/mean"
table 6
echo
echo "## Fleet total ingress (sum of the 9 relays at each second)"
echo "window         mean       p50       p95       p99       max   pk/mean"
table 5
