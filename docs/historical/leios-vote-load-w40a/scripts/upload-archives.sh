#!/usr/bin/env bash
# Upload the raw netdata archives for the w40a vote load test to S3.
#
# Run this yourself: it needs AWS credentials the agent sandbox does not have.
#
# Contents are host telemetry only — throughput, CPU, disk, memory, TCP counters,
# PSI — keyed by hostname and netdata chart name. No addresses, no peer identities,
# no credentials. Hostnames already appear in this repo's colmena config.
#
# Four archives, ~1.5 GB in total, living outside the repo:
#
#   data-1s           interface throughput, six 1-hour windows on 10-09
#   data-1s-wide      ~100 charts per host, the same six windows
#   data-weekend      interface throughput, 58 continuous hours to 10-12 00:00
#   data-weekend-wide ~100 charts per host, the same 58 hours. 1.3 GB on its own.
#
# Point SRC at the directory holding them:
#
#   SRC=/path/to/vote-load-test ./scripts/upload-archives.sh
#
# ARCHIVES can be narrowed to re-upload just one, e.g. after a partial re-pull:
#
#   ARCHIVES=data-weekend-wide DRY_RUN=0 ./scripts/upload-archives.sh
#
set -euo pipefail

SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
BUCKET="${BUCKET:-cardano-playground-public}"
PREFIX="${PREFIX:-leios/vote-load-w40a-2026-10-09}"
DEST="s3://$BUCKET/$PREFIX"
ARCHIVES="${ARCHIVES:-data-1s data-1s-wide data-weekend data-weekend-wide}"

missing=""
for d in $ARCHIVES; do
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

paths=""
for d in $ARCHIVES; do paths="$paths $SRC/$d"; done

echo "source: $SRC"
echo "dest:   $DEST"
echo "        $(find $paths -name "*.csv.gz" | wc -l) archive files, $(du -ch $paths | tail -1 | cut -f1) total"
for d in $ARCHIVES; do
  printf "        %-18s %6s  %3d files\n" "$d" \
    "$(du -sh "$SRC/$d" | cut -f1)" "$(ls "$SRC/$d"/*.csv.gz 2>/dev/null | wc -l)"
done
echo

if [ "${DRY_RUN:-1}" = "1" ]; then
  echo "DRY RUN. Set DRY_RUN=0 to upload."
  EXTRA="--dryrun"
else
  EXTRA=""
fi

for d in $ARCHIVES; do
  aws s3 sync "$SRC/$d" "$DEST/$d" $EXTRA \
    --exclude "*" --include "*.csv.gz" --include "README.md" --include "MANIFEST.txt" \
    --only-show-errors
done
aws s3 cp "$SRC/data-1s/stats-summary.txt" "$DEST/stats-summary.txt" $EXTRA --only-show-errors
aws s3 cp "$SRC/data-1s/mimir-windows.tsv" "$DEST/mimir-windows.tsv" $EXTRA --only-show-errors
[ -f "$SRC/MANIFEST.txt" ] && aws s3 cp "$SRC/MANIFEST.txt" "$DEST/MANIFEST.txt" $EXTRA --only-show-errors

echo
echo "verify:"
echo "  aws s3 ls --recursive --human-readable --summarize $DEST/"
