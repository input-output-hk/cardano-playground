#!/usr/bin/env bash
# Append load hour 4 (20:05-21:05 UTC) to both existing archives.
# Concatenated gzip members decompress as one stream, so appending is valid and
# avoids re-pulling the four windows already held.
set -uo pipefail
cd "$(dirname "$0")/.."
GZ="${GZIP:-$(command -v gzip)}"
W=load4; S=20:05; E=21:05
HOSTS="leios1-rel-a-1 leios1-rel-a-2 leios1-rel-a-3 leios2-rel-b-1 leios2-rel-b-2 leios2-rel-b-3
       leios3-rel-c-1 leios3-rel-c-2 leios3-rel-c-3 leiosred1-bp-a-1 leiosred5-bp-e-1
       leiosred10-bp-j-1 leios1-bp-a-1 leios2-bp-b-1 leios3-bp-c-1 leios1-dbsync-a-1
       leios1-centrifuge-a-1 leios1-faucet-a-1 leios1-metsuke-a-1"

for h in $HOSTS; do
  n="data-1s/$h.csv.gz"
  if [ -s "$n" ] && ! $GZ -cd "$n" | grep -qm1 "^$W,"; then
    timeout 180 bash /tmp/sshw "$h" "
      IF=\$(curl -s localhost:19999/api/v1/charts | jq -r '.charts|keys[]|select(test(\"^net\\\\.\"))' | head -1)
      A=\$(date -u -d '2026-10-09T$S:00Z' +%s); B=\$(date -u -d '2026-10-09T$E:00Z' +%s)
      curl -s \"localhost:19999/api/v1/data?chart=\$IF&after=\$A&before=\$B&points=3600&format=csv&options=seconds\" \
        | tail -n +2 | sed \"s|^|$W,$h,\$IF,|\" | gzip -9" 2>/dev/null >> "$n"
    echo "  narrow $h: $($GZ -cd "$n" | grep -c "^$W,") load4 rows"
  fi
  w="data-1s-wide/$h.csv.gz"
  if [ -s "$w" ] && ! $GZ -cd "$w" | grep -qm1 "^\"$W\""; then
    timeout 420 bash /tmp/sshw "$h" "WIN_ONLY='$W:$S:$E' bash -s" < scripts/pull-wide-remote.sh 2>/dev/null >> "$w"
    echo "  wide   $h: $($GZ -cd "$w" | grep -c "^\"$W\"") load4 rows"
  fi
done
echo LOAD4DONE
