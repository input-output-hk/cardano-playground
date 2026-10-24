#!/usr/bin/env bash
# Pull continuous 1-second interface bandwidth for the whole load-test weekend,
# 2026-10-09 14:00 UTC through 2026-10-12 00:00 UTC, into data-weekend/.
#
# Chunked per UTC day: one netdata request for 58 hours would be ~209k points
# per host, large enough to be worth splitting.
#
# netdata tier 0 keeps 1s samples for a requested 14 days, bounded by disk; measured
# 2026-10-12 the actual span ran 8d22h to 21d8h across these hosts. Check the first
# row's timestamp of any output file to confirm the early hours really came back at
# 1s rather than aggregated from a coarser tier.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-data-weekend}"; mkdir -p "$OUT"
GZ="${GZIP:-$(command -v gzip || echo /nix/store/yr6ar7lsk3yfas4d464z1ysaxwcq2gc5-gzip-1.14/bin/gzip)}"

HOSTS="${HOSTS:-leios1-rel-a-1 leios1-rel-a-2 leios1-rel-a-3 leios2-rel-b-1 leios2-rel-b-2 leios2-rel-b-3
       leios3-rel-c-1 leios3-rel-c-2 leios3-rel-c-3 leiosred1-bp-a-1 leiosred5-bp-e-1 leiosred10-bp-j-1
       leios1-bp-a-1 leios2-bp-b-1 leios3-bp-c-1 leios1-dbsync-a-1 leios1-centrifuge-a-1
       leios1-faucet-a-1 leios1-metsuke-a-1}"

# label@start@end, UTC, chunked per day. @ not : because timestamps contain colons, and
# all on one line because this string is interpolated into a remote "for ...; do".
CHUNKS="d09@2026-10-09T14:00:00Z@2026-10-10T00:00:00Z d10@2026-10-10T00:00:00Z@2026-10-11T00:00:00Z d11@2026-10-11T00:00:00Z@2026-10-12T00:00:00Z"

valid_archive() {
  "$GZ" -t "$1" 2>/dev/null &&
    [ "$("$GZ" -cd "$1" | wc -l)" -eq 208801 ]
}
failed=0
for h in $HOSTS; do
  f="$OUT/$h.csv.gz"
  [ -s "$f" ] && valid_archive "$f" && { echo "skip $h (complete)"; continue; }
  part=$(mktemp "$f.part.XXXXXX")
  echo "pulling $h ..."
  if timeout 900 bash /tmp/sshw "$h" "
    set -euo pipefail
    IF=\$(curl --fail --silent --show-error --connect-timeout 10 --max-time 300 localhost:19999/api/v1/charts | jq -r '.charts|keys[]|select(test(\"^net\\\\.\"))' | sed -n '1p')
    for c in $CHUNKS; do
      L=\${c%%@*}; R=\${c#*@}
      S=\${R%@*}; E=\${R#*@}
      A=\$(date -u -d \"\$S\" +%s); B=\$(date -u -d \"\$E\" +%s)
      curl --fail --silent --show-error --connect-timeout 10 --max-time 300 \"localhost:19999/api/v1/data?chart=\$IF&after=\$A&before=\$B&format=csv&options=seconds\" \
        | tail -n +2 | sed \"s|^|\$L,$h,\$IF,|\"
    done | gzip -9
  " > "$part" && valid_archive "$part"; then
    mv "$part" "$f"
    echo "  verified 208801 rows for $h"
  else
    echo "ERROR: $h request failed or archive is incomplete" >&2
    rm -f "$part"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1
echo WEEKENDDONE
