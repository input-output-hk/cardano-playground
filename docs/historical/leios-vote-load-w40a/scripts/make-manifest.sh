#!/usr/bin/env bash
# Regenerate the top-level MANIFEST.txt covering every archive file in every data-*/ dir.
#
# Sizes are apparent (stat), not du: these directories sit on zfs, where du reports the
# compressed on-disk size and would not match a downloaded copy.
#
# Each file is gzip-tested first. A dropped ControlMaster during collection truncates the
# stream mid-record, leaving a file that is large and plausible but incomplete, so a
# manifest that only recorded size and digest would faithfully describe a broken archive.
set -uo pipefail
cd "$(dirname "$0")/.."
GZ="${GZIP:-$(command -v gzip || ls /nix/store/*gzip-1.14/bin/gzip 2>/dev/null | head -1)}"
OUT="${OUT:-MANIFEST.txt}"

bad=0
{
  cat <<'HDR'
# Raw netdata archives for the w40a vote load test. Paths are relative to this directory.
# bytes is apparent size; the archives live on zfs, where du reports a smaller number.
#
# Verify a download against this file:
#   awk '!/^#|^file/ {print $3"  "$1}' MANIFEST.txt | sha256sum -c
#
HDR
  printf "%-46s %12s  %s\n" file bytes sha256
  for d in data-*/; do
    for f in "$d"*.csv.gz; do
      [ -e "$f" ] || continue
      if ! "$GZ" -t "$f" 2>/dev/null; then
        echo "# TRUNCATED, re-pull: $f" >&2; bad=$((bad+1)); continue
      fi
      printf "%-46s %12s  %s\n" "$f" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
    done
  done
} > "$OUT"

n=$(grep -c "csv.gz" "$OUT")
tot=$(awk '!/^#|^file/ {s+=$2} END{print s}' "$OUT")
echo "wrote $OUT: $n files, $(numfmt --to=iec "$tot") apparent"
[ "$bad" -gt 0 ] && { echo "WARNING: $bad truncated file(s) omitted" >&2; exit 1; }
exit 0
