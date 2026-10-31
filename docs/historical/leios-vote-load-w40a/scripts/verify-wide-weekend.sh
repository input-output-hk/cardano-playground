#!/usr/bin/env bash
# Integrity pass over data-weekend-wide/. One line per host plus a MANIFEST.
#
# Each archive should cover exactly 2026-10-09 14:00:00 to 2026-10-12 00:00:00 UTC in
# three per-day windows. Charts collect at their own intervals, so rows per host is not
# a fixed number and is reported rather than asserted.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="${DIR:-data-weekend-wide}"
GZ="${GZIP:-$(command -v gzip || ls /nix/store/*gzip-1.14/bin/gzip 2>/dev/null | head -1)}"

EXP_A=$(date -u -d 2026-10-09T14:00:00Z +%s)
EXP_B=$(date -u -d 2026-10-12T00:00:00Z +%s)

out="$DIR/MANIFEST.txt"
manifest=$(mktemp "$DIR/.MANIFEST.XXXXXX")
trap 'rm -f "$manifest"' EXIT
failed=0
count=0
{
  cat <<'HDR'
# Wide weekend archive, 19 hosts, 2026-10-09 14:00:00 to 2026-10-12 00:00:00 UTC.
# bytes is apparent size; this directory is on zfs, so du reports a smaller number.
#
# Verify a download against this file:
#   awk '!/^#|^host/ {print $11"  "$1".csv.gz"}' MANIFEST.txt | sha256sum -c
#
HDR
  printf "%-24s %10s %12s %7s %6s %8s %-20s %-20s %s\n" \
    host rows bytes charts dims windows earliest latest sha256
  for f in "$DIR"/*.csv.gz; do
    [ -e "$f" ] || continue
    count=$((count + 1))
    h=$(basename "$f" .csv.gz)
    # Catch a severed stream before trusting any count derived from it: gzip -cd emits
    # the rows it did get and exits non-zero, so a truncated file otherwise looks merely small.
    if ! "$GZ" -t "$f" 2>/dev/null; then
      echo "ERROR: $h has a truncated gzip stream; re-pull this host" >&2
      failed=1
      continue
    fi
    s=$("$GZ" -cd "$f" | awk -F',' '
      {gsub(/"/,"",$1); gsub(/"/,"",$3); gsub(/"/,"",$4); gsub(/"/,"",$5)
       n++; c[$3]++; d[$3"|"$4]++; w[$1]++
       t=$5+0; if(mn==0||t<mn)mn=t; if(t>mx)mx=t}
      END{print n, length(c), length(d), length(w), mn, mx}')
    read -r n nc nd nw mn mx <<<"$s"
    sha=$(sha256sum "$f" | cut -d" " -f1)
    printf "%-24s %10d %12s %7d %6d %8d %-20s %-20s %s\n" \
      "$h" "$n" "$(stat -c%s "$f")" "$nc" "$nd" "$nw" \
      "$(date -u -d @"$mn" '+%F %T')" "$(date -u -d @"$mx" '+%F %T')" "$sha"
    [ "$mn" = "$EXP_A" ] || { failed=1; echo "  ERROR $h starts $(date -u -d @"$mn" '+%F %T'), expected 2026-10-09 14:00:00" >&2; }
    [ "$mx" = "$EXP_B" ] || { failed=1; echo "  ERROR $h ends $(date -u -d @"$mx" '+%F %T'), expected 2026-10-12 00:00:00" >&2; }
    [ "$nw" -eq 3 ] || { failed=1; echo "  ERROR $h has $nw windows, expected 3" >&2; }
  done
} > "$manifest"
if [ "$count" -eq 0 ]; then
  echo "ERROR: no archives found in $DIR" >&2
  failed=1
fi
[ "$failed" -eq 0 ] || exit 1
mv "$manifest" "$out"
cat "$out"
echo "wrote $out"
echo VERIFYDONE
