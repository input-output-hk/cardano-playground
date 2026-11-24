#!/usr/bin/env bash
# Driver: full-weekend wide netdata pull, 2026-10-09 14:00 -> 2026-10-12 00:00 UTC.
# ~150 MB gz per host, ~2.8 GB total. Skips hosts already pulled, safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-data-weekend-wide}"; mkdir -p "$OUT"
GZ="${GZIP:-$(command -v gzip || echo /nix/store/yr6ar7lsk3yfas4d464z1ysaxwcq2gc5-gzip-1.14/bin/gzip)}"
HOSTS="${HOSTS:-leios1-rel-a-1 leios1-rel-a-2 leios1-rel-a-3 leios2-rel-b-1 leios2-rel-b-2 leios2-rel-b-3
       leios3-rel-c-1 leios3-rel-c-2 leios3-rel-c-3 leiosred1-bp-a-1 leiosred5-bp-e-1 leiosred10-bp-j-1
       leios1-bp-a-1 leios2-bp-b-1 leios3-bp-c-1 leios1-dbsync-a-1 leios1-centrifuge-a-1
       leios1-faucet-a-1 leios1-metsuke-a-1}"
# A dropped ControlMaster ends the stream mid-record, leaving a file that is large and
# plausible but truncated. A row-count floor does not catch that: one host came back with
# 9.4M rows, two of three windows, and a severed last record. Accept a pull only if the
# gzip stream is complete AND all three day-chunks are present.
valid_archive() {
  "$GZ" -t "$1" 2>/dev/null &&
    "$GZ" -cd "$1" | awk -F, '
      {gsub(/"/, "", $1); w[$1]++}
      END {exit !(length(w) == 3 && w["d09"] && w["d10"] && w["d11"])}'
}
failed=0
for h in $HOSTS; do
  f="$OUT/$h.csv.gz"
  if [ -s "$f" ] && valid_archive "$f"; then
    echo "skip $h (complete)"; continue
  fi
  echo "pulling $h ... ($(date -u +%T))"
  part=$(mktemp "$f.part.XXXXXX")
  if timeout 3600 bash /tmp/sshw "$h" 'bash -s' < scripts/pull-wide-weekend-remote.sh > "$part" && valid_archive "$part"; then
    mv "$part" "$f"
    echo "  verified $h"
  else
    echo "ERROR: $h request failed or archive is incomplete" >&2
    rm -f "$part"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1
echo "TOTAL: $(du -sh "$OUT" | cut -f1)"
echo WIDEWEEKENDDONE
