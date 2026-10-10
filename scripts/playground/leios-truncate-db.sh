#!/usr/bin/env bash
#
# Truncate leios.db to match a chainDB rewind.
#
# Drops every ebs/ebTxs row with ebSlot > target_slot, then garbage-collects
# txs that are no longer referenced by any surviving EB. Backs up the db
# first (unless --no-backup). The node MUST be stopped before running this.
#
# The target slot can be supplied directly via --slot, or computed from a
# wallclock time + the chain's system-start (+ optional slot length).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  leios-truncate-db.sh --db PATH (--slot N | --time T --system-start T)
                       [--slot-length SECS] [--yes] [--dry-run]
                       [--no-backup] [--no-vacuum]

Required:
  --db PATH              Path to leios.db. The owning node must be stopped.

  And one of:
  --slot N               Drop rows where ebSlot > N.
  --time TIMESTAMP       Target wallclock (RFC3339, e.g. 2026-06-01T16:00:00Z).
                         Requires --system-start.

If using --time:
  --system-start TS      Chain system-start time (RFC3339). Read from genesis.
  --slot-length SECS     Seconds per slot (default 1).

Behaviour:
  --yes, -y              Skip the interactive confirmation prompt.
  --dry-run              Print pre-flight counts and exit without modifying.
  --no-backup            Skip the .bak.<ts> copy (default: backup is made).
  --no-vacuum            Skip the post-delete VACUUM (frees disk space).

Examples:
  Direct slot:
    leios-truncate-db.sh --db /var/lib/cardano-node/db-leios/leios.db \
                         --slot 327600

  From wallclock (1s slots, system-start from genesis):
    leios-truncate-db.sh --db ./leios.db \
                         --time 2026-06-01T16:00:00Z \
                         --system-start 2026-04-15T00:00:00Z
EOF
  exit "${1:-2}"
}

DB=""
SLOT=""
TARGET_TIME=""
SYSTEM_START=""
SLOT_LENGTH=1
YES=0
DRY_RUN=0
DO_BACKUP=1
DO_VACUUM=1

while [ $# -gt 0 ]; do
  case "$1" in
    --db)            DB="$2";            shift 2 ;;
    --slot)          SLOT="$2";          shift 2 ;;
    --time)          TARGET_TIME="$2";   shift 2 ;;
    --system-start)  SYSTEM_START="$2";  shift 2 ;;
    --slot-length)   SLOT_LENGTH="$2";   shift 2 ;;
    --yes|-y)        YES=1;              shift   ;;
    --dry-run)       DRY_RUN=1;          shift   ;;
    --no-backup)     DO_BACKUP=0;        shift   ;;
    --no-vacuum)     DO_VACUUM=0;        shift   ;;
    -h|--help)       usage 0 ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

command -v sqlite3 >/dev/null 2>&1 || {
  echo "ERROR: sqlite3 not found in PATH. Try:" >&2
  echo "       nix shell nixpkgs#sqlite --command $0 $*" >&2
  exit 1
}

[ -n "$DB" ] || { echo "ERROR: --db is required" >&2; usage; }
[ -f "$DB" ] || { echo "ERROR: $DB not found" >&2; exit 1; }

# Resolve target slot.
if [ -n "$SLOT" ]; then
  :
elif [ -n "$TARGET_TIME" ] && [ -n "$SYSTEM_START" ]; then
  target_epoch=$(date -u -d "$TARGET_TIME" +%s)
  start_epoch=$(date -u -d "$SYSTEM_START" +%s)
  if [ "$target_epoch" -lt "$start_epoch" ]; then
    echo "ERROR: --time is before --system-start" >&2
    exit 1
  fi
  SLOT=$(( (target_epoch - start_epoch) / SLOT_LENGTH ))
  echo "Computed target slot: $SLOT"
  echo "  from --time $TARGET_TIME"
  echo "  with --system-start $SYSTEM_START"
  echo "  at slot length ${SLOT_LENGTH}s"
else
  echo "ERROR: provide either --slot, or both --time and --system-start" >&2
  usage
fi

case "$SLOT" in
  ''|*[!0-9]*) echo "ERROR: target slot '$SLOT' is not a non-negative integer" >&2; exit 1 ;;
esac

# Confirm db isn't being held open (best-effort; sqlite will error out on
# locked db anyway during DELETE/VACUUM, but a hint helps).
if command -v lsof >/dev/null 2>&1; then
  if lsof -t "$DB" >/dev/null 2>&1; then
    echo "WARNING: another process has $DB open." >&2
    echo "         Stop cardano-node before proceeding." >&2
    if [ "$YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
      printf "Continue anyway? [y/N] "
      read -r answer
      case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
    fi
  fi
fi

echo
echo "=== Database state ($DB) ==="
sqlite3 "$DB" <<'SQL'
SELECT
  'EB slot range  : ' || COALESCE(MIN(ebSlot) || ' .. ' || MAX(ebSlot), 'EMPTY')
FROM ebs;
SELECT 'ebs   rows     : ' || COUNT(*) FROM ebs;
SELECT 'ebTxs rows     : ' || COUNT(*) FROM ebTxs;
SELECT 'txs   rows     : ' || COUNT(*) FROM txs;
SQL

# Pre-flight: count what would be deleted.
echo
echo "=== Pre-flight (target slot $SLOT) ==="
EB_DROP=$(sqlite3 "$DB" "SELECT COUNT(*) FROM ebs WHERE ebSlot > $SLOT;")
EBTX_DROP=$(sqlite3 "$DB" "
  SELECT COUNT(*) FROM ebTxs
  WHERE ebHashBytes IN (SELECT ebHashBytes FROM ebs WHERE ebSlot > $SLOT);
")
TX_ORPHANS=$(sqlite3 "$DB" "
  SELECT COUNT(*) FROM txs
  WHERE txHashBytes NOT IN (
    SELECT DISTINCT txHashBytes FROM ebTxs
    WHERE ebHashBytes NOT IN
      (SELECT ebHashBytes FROM ebs WHERE ebSlot > $SLOT)
  );
")
echo "  ebs rows to drop          : $EB_DROP"
echo "  ebTxs rows to drop        : $EBTX_DROP"
echo "  txs that become orphan    : $TX_ORPHANS"

if [ "$EB_DROP" -eq 0 ]; then
  echo
  echo "Nothing to do (no EBs past slot $SLOT). Exiting."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Dry run; no changes made."
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  echo
  printf "Proceed with delete + VACUUM? [y/N] "
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Online-safe backup via sqlite's own .backup (handles WAL correctly).
if [ "$DO_BACKUP" -eq 1 ]; then
  backup="${DB}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  echo
  echo "Backing up to $backup ..."
  sqlite3 "$DB" ".backup '$backup'"
  echo "  $(du -h "$backup" | cut -f1)"
fi

echo
echo "Running purge transaction ..."
sqlite3 "$DB" <<SQL
PRAGMA foreign_keys = OFF;
BEGIN;
CREATE TEMP TABLE _drop_ebs AS
  SELECT ebHashBytes FROM ebs WHERE ebSlot > $SLOT;
DELETE FROM ebTxs
  WHERE ebHashBytes IN (SELECT ebHashBytes FROM _drop_ebs);
DELETE FROM ebs WHERE ebSlot > $SLOT;
DELETE FROM txs
  WHERE txHashBytes NOT IN (SELECT DISTINCT txHashBytes FROM ebTxs);
DROP TABLE _drop_ebs;
COMMIT;
SQL

if [ "$DO_VACUUM" -eq 1 ]; then
  echo
  echo "Checkpointing WAL and VACUUM ..."
  sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"
fi

echo
echo "=== Post-state ==="
sqlite3 "$DB" <<'SQL'
SELECT
  'EB slot range  : ' || COALESCE(MIN(ebSlot) || ' .. ' || MAX(ebSlot), 'EMPTY')
FROM ebs;
SELECT 'ebs   rows     : ' || COUNT(*) FROM ebs;
SELECT 'ebTxs rows     : ' || COUNT(*) FROM ebTxs;
SELECT 'txs   rows     : ' || COUNT(*) FROM txs;
SQL

echo
echo "Done."
