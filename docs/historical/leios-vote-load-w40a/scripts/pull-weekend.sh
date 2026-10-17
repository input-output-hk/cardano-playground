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
set -uo pipefail
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

for h in $HOSTS; do
  f="$OUT/$h.csv.gz"
  [ -s "$f" ] && { echo "skip $h (exists)"; continue; }
  echo "pulling $h ..."
  timeout 900 bash /tmp/sshw "$h" "
    IF=\$(curl -s localhost:19999/api/v1/charts | jq -r '.charts|keys[]|select(test(\"^net\\\\.\"))' | head -1)
    for c in $CHUNKS; do
      L=\${c%%@*}; R=\${c#*@}
      S=\${R%@*}; E=\${R#*@}
      A=\$(date -u -d \"\$S\" +%s); B=\$(date -u -d \"\$E\" +%s)
      curl -s \"localhost:19999/api/v1/data?chart=\$IF&after=\$A&before=\$B&format=csv&options=seconds\" \
        | tail -n +2 | sed \"s|^|\$L,$h,\$IF,|\"
    done | gzip -9
  " 2>/dev/null > "$f"
  # A dropped ControlMaster truncates the stream mid-record, producing a file that is
  # large and plausible but short. Require a complete gzip stream and the full row count
  # (58 x 3600 + 1; the API returns both range endpoints) rather than a loose floor.
  if ! "$GZ" -t "$f" 2>/dev/null; then
    echo "  TRUNCATED gzip stream, removing"; rm -f "$f"; continue
  fi
  n=$($GZ -cd "$f" | wc -l)
  if [ "$n" -ne 208801 ]; then echo "  $n rows, expected 208801, removing"; rm -f "$f"; else
    first=$($GZ -cd "$f" | head -1 | cut -d, -f4)
    echo "  $n rows, $(stat -c%s "$f") bytes, earliest $(date -u -d @"$first" +%F\ %T)"
  fi
done
echo WEEKENDDONE
