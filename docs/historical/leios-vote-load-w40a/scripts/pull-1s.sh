#!/usr/bin/env bash
# Pull 1-second network data from each relay's local netdata and archive it.
# netdata tier0 holds 1s data for ~96h+; this makes the load-test windows permanent.
# Compression happens on the remote host; the agent sandbox has no gzip.
set -uo pipefail
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/data-1s}"
mkdir -p "$OUT"
GZIP="${GZIP:-$(command -v gzip || echo "$(nix build --no-link --print-out-paths nixpkgs#gzip)/bin/gzip")}"

RELAYS="leios1-rel-a-1 leios1-rel-a-2 leios1-rel-a-3 leios2-rel-b-1 leios2-rel-b-2 leios2-rel-b-3 leios3-rel-c-1 leios3-rel-c-2 leios3-rel-c-3"
WINDOWS="base_11:10:05:11:05 base_13:12:05:13:05 load1:14:05:15:05 load2:16:05:17:05 load3:18:05:19:05"

for h in $RELAYS; do
  f="$OUT/$h.csv.gz"
  [ -s "$f" ] && { echo "skip $h (exists)"; continue; }
  echo "pulling $h ..."
  timeout 300 bash /tmp/sshw "$h" "
    IF=\$(curl -s localhost:19999/api/v1/charts | jq -r '.charts|keys[]|select(test(\"^net\\\\.\"))' | head -1)
    for w in $WINDOWS; do
      L=\${w%%:*}; R=\${w#*:}
      S=\$(echo \$R | cut -d: -f1-2); E=\$(echo \$R | cut -d: -f3-4)
      A=\$(date -u -d \"2026-10-09T\$S:00Z\" +%s); B=\$(date -u -d \"2026-10-09T\$E:00Z\" +%s)
      curl -s \"localhost:19999/api/v1/data?chart=\$IF&after=\$A&before=\$B&points=3600&format=csv&options=seconds\" \
        | tail -n +2 | sed \"s|^|\$L,$h,\$IF,|\"
    done | gzip -9
  " 2>/dev/null > "$f"
  echo "  $($GZIP -cd "$f" | wc -l) rows, $(stat -c%s "$f") bytes"
done
echo DONE
