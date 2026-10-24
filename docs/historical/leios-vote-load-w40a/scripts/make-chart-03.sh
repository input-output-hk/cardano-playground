#!/usr/bin/env bash
# Regenerate charts/03-egress-by-host-class.png from the 1-second archives.
#
# Unloaded peak comes from data-1s (the two pre-load on-hours on 10-09, base_11 and
# base_13); loaded peak is the maximum across every loaded on-hour in data-weekend,
# 10-09 14:05 through 10-12 00:00.
#
# On-hours are the txgen duty cycle: a window runs H:05 to H+1:05 with H even. A
# timestamp is inside one when (hour even and minute >= 5) or (hour odd and minute < 5).
# Comparing an on-hour to an off-hour measures the duty cycle, not the load.
#
# netdata reports net.* dimensions in kilobits/s with egress negative, so values are
# negated and divided by 1000 to reach Mbit/s.
set -euo pipefail
cd "$(dirname "$0")/.."

GZ="${GZIP:-$(command -v gzip || ls /nix/store/*gzip-1.14/bin/gzip 2>/dev/null | head -1)}"
GP="${GNUPLOT:-$(command -v gnuplot || ls /nix/store/*gnuplot-6.0.5/bin/gnuplot 2>/dev/null | head -1)}"
OUT="${OUT:-charts/03-egress-by-host-class.png}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# First loaded on-hour, 2026-10-09 14:05:00Z.
LOAD_FROM=$(date -u -d 2026-10-09T14:05:00Z +%s)

short() {
  case $1 in
    leios[123]-rel-*) echo "${1#leios?-}" | sed 's/rel-/rel-/' ;;
    leiosred*-bp-*)   echo "red${1#leiosred}" | sed 's/-bp-.*/-bp/' ;;
    leios[123]-bp-*)  echo "ctl-bp-${1#leios?-bp-}" | cut -d- -f1-3 ;;
    *)                echo "$1" | sed 's/^leios[0-9]*-//; s/-a-1$//' ;;
  esac
}
order() {
  case $1 in leios[123]-rel-*) echo 1;; leiosred*-bp-*) echo 2;;
             leios[123]-bp-*) echo 3;; *) echo 4;; esac
}
# Secondary sort key, so leiosred10 follows leiosred5 instead of leiosred1.
subnum() {
  case $1 in leiosred*-bp-*) n=${1#leiosred}; echo "${n%%-*}" ;; *) echo 0 ;; esac
}

for f in data-1s/*.csv.gz; do
  h=$(basename "$f" .csv.gz)
  [ -s "data-weekend/$h.csv.gz" ] || { echo "skip $h (no weekend archive)" >&2; continue; }
  u=$("$GZ" -cd "$f" | awk -F, '
        $1=="base_11"||$1=="base_13"{v=($6<0?-$6:$6)/1000; if(v>m)m=v} END{printf "%.1f", m+0}')
  l=$("$GZ" -cd "data-weekend/$h.csv.gz" | awk -F, -v from="$LOAD_FROM" '
        {t=$4+0; hh=int((t%86400)/3600); mm=int((t%3600)/60)
         if(t>=from && ((hh%2==0&&mm>=5)||(hh%2==1&&mm<5))){
           v=($6<0?-$6:$6)/1000; if(v>m)m=v}} END{printf "%.1f", m+0}')
  echo "$(order "$h") $(subnum "$h") $(short "$h") $u $l"
done | sort -k1,1n -k2,2n -k3,3 | awk '{print $3, $4, $5}' > "$TMP/d.tsv"

echo "host data:"; cat "$TMP/d.tsv" | sed 's/^/  /'
n=$(wc -l < "$TMP/d.tsv")

"$GP" <<EOF
set terminal pngcairo size 1500,680 enhanced font 'DejaVu Sans,13' background rgb '#fcfcfb'
set output '$OUT'

set tmargin at screen 0.76
set bmargin at screen 0.17
set lmargin at screen 0.072
set rmargin at screen 0.985

set label 98 "Peak egress by host class" \
  at screen 0.072,0.955 left font 'DejaVu Sans,18' tc rgb '#26262a'
set label 99 "highest 1-second egress: 2 unloaded on-hours vs the maximum across 29 loaded on-hours" \
  at screen 0.072,0.908 left font 'DejaVu Sans,11.5' tc rgb '#6a6a66'

set style data histograms
set style histogram clustered gap 2
set style fill solid 1.0 noborder
set boxwidth 0.88

set logscale y
set yrange [5:1150]
set ytics (5,10,25,50,100,250,500) nomirror tc rgb '#6a6a66'
set ylabel "peak Mbit/s (1-second, log scale)" tc rgb '#3a3a38' offset 1.4
set grid ytics lc rgb '#e6e6e2' lw 1
set border 2 lc rgb '#d0d0cc'
set xtics nomirror scale 0 rotate by 30 right offset -0.6,0 \
  tc rgb '#3a3a38' font 'DejaVu Sans,11.5'
set key at screen 0.985,0.955 right horizontal samplen 1.2 width 1 \
  font 'DejaVu Sans,12.5' tc rgb '#3a3a38'

# Class spans, drawn just under the plot's top edge.
set arrow 1 from -0.5,700 to 8.5,700   nohead lc rgb '#c2c2be' lw 1.4
set label 1 "relays"        at 4,880    center tc rgb '#6a6a66' font 'DejaVu Sans,11.5'
set arrow 2 from 8.6,700 to 11.5,700   nohead lc rgb '#f0552b' lw 1.6
set label 2 "load-test BPs" at 10.05,880 center tc rgb '#f0552b' font 'DejaVu Sans,11.5'
set arrow 3 from 11.6,700 to 14.5,700  nohead lc rgb '#c2c2be' lw 1.4
set label 3 "control BPs"   at 13.05,880 center tc rgb '#6a6a66' font 'DejaVu Sans,11.5'
set arrow 4 from 14.6,700 to $((n-1)).5,700 nohead lc rgb '#c2c2be' lw 1.4
set label 4 "support"       at 16.6,880 center tc rgb '#6a6a66' font 'DejaVu Sans,11.5'

plot '$TMP/d.tsv' using 2:xtic(1) title 'unloaded peak' lc rgb '#2878c8', \
                '' using 3        title 'loaded peak'   lc rgb '#f0552b'
EOF

echo "wrote $OUT"
