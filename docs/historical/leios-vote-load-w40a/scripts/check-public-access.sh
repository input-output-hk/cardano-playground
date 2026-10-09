#!/usr/bin/env bash
# Is the uploaded archive anonymously downloadable?
#
# Checks each key twice: signed (does it exist?) and anonymous (can the world read
# it?). Both are needed, because when anonymous ListBucket is denied S3 answers 403
# for a missing key as well as for a protected one — so a bare 403 alone proves
# nothing about whether the upload landed.
set -uo pipefail

BUCKET="${BUCKET:-cardano-playground-public}"
PREFIX="${PREFIX:-leios/vote-load-w40a-2026-10-09}"
KEYS="${KEYS:-MANIFEST.txt data-1s/leios1-rel-a-1.csv.gz data-1s-wide/leios1-rel-a-1.csv.gz}"

REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" --output text 2>/dev/null)
[ "$REGION" = "None" ] || [ -z "$REGION" ] && REGION=us-east-1
HOST="$BUCKET.s3.$REGION.amazonaws.com"
echo "bucket: $BUCKET   region: $REGION"
echo

printf "%-44s %-10s %-10s %s\n" key exists anon verdict
for k in $KEYS; do
  if aws s3api head-object --bucket "$BUCKET" --key "$PREFIX/$k" >/dev/null 2>&1; then
    exists=yes
  else
    exists=NO
  fi
  code=$(curl -sIL -o /dev/null -w '%{http_code}' "https://$HOST/$PREFIX/$k")
  case "$exists:$code" in
    yes:200) v="PUBLIC - world readable" ;;
    yes:40*) v="private (good)" ;;
    NO:*)    v="NOT UPLOADED" ;;
    *)       v="unexpected" ;;
  esac
  printf "%-44s %-10s %-10s %s\n" "$k" "$exists" "$code" "$v"
done

echo
echo "anonymous bucket listing:"
aws s3 ls --no-sign-request "s3://$BUCKET/$PREFIX/" 2>&1 | head -3 \
  || echo "  denied (good)"
