#!/usr/bin/env bash
# recover_bp.sh <target-host> <donor-relay>
#
# Reseed a forked/behind Leios node's consensus chain state from a healthy
# donor relay's nginx full artifact, then restart it so it rejoins the main chain.
#
# MUTATING — confirm with an SRE before running (see SKILL.md "Mutation policy").
# Non-destructive to the old state: the target's current chain DB is moved aside
# to *.fork-bak (not deleted) so you can inspect or roll back.
#
# Assumes (verify per deployment — see SKILL.md §"Storage layout"):
#   - target & donor share the Leios split-storage layout:
#       /var/lib/cardano-node/db-leios      (RB/ledger chain DB, on EBS)
#       /ephemeral/cardano-node/leios.db    (Leios EB/vote DB, on ephemeral)
#   - donor relay publishes a fresh full artifact at
#       /ephemeral/nginx-artifacts/leios.full.tar.zst (+ .sha256)
#     containing top-level `db-leios/` and `leios.db` (typically only -rel-*-1 relays).
#   - `wush` is on both hosts; the agent drives both via /tmp/sshw (cluster-ssh skill).
#   - the cardano-node systemd unit is `cardano-node`.
#
# The donor's artifact must be on the MAIN chain (relays track it) and recent
# (hourly snapshots; the target replays + catches up the gap from its relays).
set -uo pipefail
BP=$1; RELAY=$2
S="bash /tmp/sshw"
log(){ echo "[$BP] $*"; }

log "stop + reset-failed"
$S "$BP" 'systemctl stop cardano-node; systemctl reset-failed cardano-node 2>/dev/null || true; echo "  state=$(systemctl is-active cardano-node)"'

log "start wush serve on $RELAY"
$S "$RELAY" "pkill -x wush 2>/dev/null; sleep 1; cd /ephemeral/nginx-artifacts && setsid bash -c 'nohup wush serve >/tmp/wush-$BP.log 2>&1 &'; echo launched"
sleep 9
KEY=$($S "$RELAY" "grep -oE '^[A-Za-z0-9]{60,}\$' /tmp/wush-$BP.log | head -1")
log "key=${KEY:0:12}..."
[ -z "$KEY" ] && { log "FAILED: no wush key"; exit 1; }

log "pull + verify artifact"
$S "$BP" "rm -rf /ephemeral/art-in && mkdir -p /ephemeral/art-in && cd /ephemeral/art-in && \
  wush rsync --auth-key $KEY :/ephemeral/nginx-artifacts/leios.full.tar.zst . -- -a 2>&1 | tail -1 && \
  wush rsync --auth-key $KEY :/ephemeral/nginx-artifacts/leios.full.tar.zst.sha256 . -- -a 2>&1 | tail -1"
SHA=$($S "$BP" "cd /ephemeral/art-in && sha256sum -c <(awk '{print \$1\"  leios.full.tar.zst\"}' leios.full.tar.zst.sha256) 2>&1")
log "sha: $SHA"
$S "$RELAY" 'pkill -x wush 2>/dev/null || true'
echo "$SHA" | grep -q ': OK' || { log "FAILED: sha mismatch"; exit 1; }

log "extract + emplace (fork db -> .fork-bak)"
$S "$BP" '
  set -e
  cd /ephemeral/art-in
  zstd -dc leios.full.tar.zst | tar -xf -
  rm -rf /var/lib/cardano-node/db-leios.fork-bak /ephemeral/cardano-node/leios.db.fork-bak
  mv /var/lib/cardano-node/db-leios /var/lib/cardano-node/db-leios.fork-bak
  mv /ephemeral/cardano-node/leios.db /ephemeral/cardano-node/leios.db.fork-bak 2>/dev/null || true
  rm -f /ephemeral/cardano-node/leios.db-wal /ephemeral/cardano-node/leios.db-shm
  cp -a /ephemeral/art-in/db-leios /var/lib/cardano-node/db-leios
  mv /ephemeral/art-in/leios.db /ephemeral/cardano-node/leios.db
  chown -R cardano-node:cardano-node /var/lib/cardano-node/db-leios /ephemeral/cardano-node/leios.db
  rm -rf /ephemeral/art-in
  systemctl reset-failed cardano-node 2>/dev/null || true
  systemctl start cardano-node
  echo "  started=$(systemctl is-active cardano-node)"
'
log "DONE - node starting/replaying"
