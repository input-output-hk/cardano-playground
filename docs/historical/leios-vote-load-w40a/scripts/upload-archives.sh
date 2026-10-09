#!/usr/bin/env bash
# Upload the raw netdata archives for the w40a vote load test to S3.
#
# Run this yourself: it needs AWS credentials the agent sandbox does not have.
#
# Contents are host telemetry only — throughput, CPU, disk, memory, TCP counters,
# PSI — keyed by hostname and netdata chart name. No addresses, no peer identities,
# no credentials. Hostnames already appear in this repo's colmena config.
#
# The archives are ~200 MB and live outside the repo. Point SRC at the directory
# holding data-1s/ and data-1s-wide/:
#
#   SRC=/path/to/vote-load-test ./scripts/upload-archives.sh
#
set -euo pipefail

SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
BUCKET="${BUCKET:-cardano-playground-public}"
PREFIX="${PREFIX:-leios/vote-load-w40a-2026-10-09}"
DEST="s3://$BUCKET/$PREFIX"

missing=""
for d in data-1s data-1s-wide; do
  [ -d "$SRC/$d" ] || missing="$missing $d"
done
if [ -n "$missing" ]; then
  cat >&2 <<MSG
error: no archives under SRC=$SRC
       missing:$missing

The archives are not in the repo. Set SRC to the directory that holds them:

  SRC=/path/to/vote-load-test $0

MSG
  exit 1
fi

echo "source: $SRC"
echo "dest:   $DEST"
echo "        $(find "$SRC/data-1s" "$SRC/data-1s-wide" -name "*.csv.gz" | wc -l) archive files, $(du -ch "$SRC/data-1s" "$SRC/data-1s-wide" | tail -1 | cut -f1) total"
echo

if [ "${DRY_RUN:-1}" = "1" ]; then
  echo "DRY RUN. Set DRY_RUN=0 to upload."
  EXTRA="--dryrun"
else
  EXTRA=""
fi

for d in data-1s data-1s-wide; do
  aws s3 sync "$SRC/$d" "$DEST/$d" $EXTRA \
    --exclude "*" --include "*.csv.gz" --include "README.md" \
    --only-show-errors
done
aws s3 cp "$SRC/data-1s/stats-summary.txt" "$DEST/stats-summary.txt" $EXTRA --only-show-errors
aws s3 cp "$SRC/data-1s/mimir-windows.tsv" "$DEST/mimir-windows.tsv" $EXTRA --only-show-errors
[ -f "$SRC/MANIFEST.txt" ] && aws s3 cp "$SRC/MANIFEST.txt" "$DEST/MANIFEST.txt" $EXTRA --only-show-errors

echo
echo "verify:"
echo "  aws s3 ls --recursive --human-readable --summarize $DEST/"
