#!/usr/bin/env bash
# Driver: run pull-wide-remote.sh on each host, store one gz per host.
# Skips hosts already pulled, so it is safe to re-run.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-data-1s-wide}"; mkdir -p "$OUT"
GZ="${GZIP:-$(command -v gzip || echo "$(nix build --no-link --print-out-paths nixpkgs#gzip)/bin/gzip")}"
HOSTS="leios1-rel-a-1 leios1-rel-a-2 leios1-rel-a-3 leios2-rel-b-1 leios2-rel-b-2 leios2-rel-b-3
       leios3-rel-c-1 leios3-rel-c-2 leios3-rel-c-3
       leiosred1-bp-a-1 leiosred5-bp-e-1 leiosred10-bp-j-1
       leios1-bp-a-1 leios2-bp-b-1 leios3-bp-c-1
       leios1-dbsync-a-1 leios1-centrifuge-a-1 leios1-faucet-a-1 leios1-metsuke-a-1"
for h in $HOSTS; do
  f="$OUT/$h.csv.gz"
  [ -s "$f" ] && { echo "skip $h"; continue; }
  echo "pulling $h ..."
  timeout 600 bash /tmp/sshw "$h" 'bash -s' < scripts/pull-wide-remote.sh > "$f" 2>/dev/null
  if [ -s "$f" ]; then
    echo "  $($GZ -cd "$f" | wc -l) rows, $(stat -c%s "$f") bytes"
  else
    echo "  FAILED (empty), removing"; rm -f "$f"
  fi
done
echo "TOTAL: $(du -sh "$OUT" | cut -f1)"
echo WIDEDONE
