#!/usr/bin/env bash
# Runs ON a cluster host. Streams gzipped tidy-long rows of netdata's native-resolution
# data for the load-test windows to stdout.
#
#   window,host,chart,dimension,unix_time,value
#
# WINDOWS entries are label@start@end with full ISO timestamps, so a window may span
# days. @ rather than : because ISO timestamps contain colons, and the list must stay
# on one line because callers interpolate it into a remote "for ...; do".
#
# No `points` parameter is sent, so each chart comes back at its own collection
# interval (1s for most, 2s for the PSI charts, 5s for system.load) rather than being
# resampled to a common grid. Check the timestamps, do not assume 1s.
set -uo pipefail
HOST=$(hostname)
ND=localhost:19999

WINDOWS="${WIN_ONLY:-base_11@2026-10-09T10:05:00Z@2026-10-09T11:05:00Z base_13@2026-10-09T12:05:00Z@2026-10-09T13:05:00Z load1@2026-10-09T14:05:00Z@2026-10-09T15:05:00Z load2@2026-10-09T16:05:00Z@2026-10-09T17:05:00Z load3@2026-10-09T18:05:00Z@2026-10-09T19:05:00Z}"

# Chart families worth keeping for this investigation. Deliberately wide: a second pull
# means another full sweep of every host, so take everything that bears on the test now.
FILTER='^net\.|^net_packets\.|^net_drops\.|^net_errors\.|^net_carrier\.'
FILTER="$FILTER"'|^system\.(cpu|load|io|ram|intr|ctxt|processes|processes_state|net|ipv4|uptime|softirqs|softnet_stat)$'
FILTER="$FILTER"'|^system\..*pressure'
FILTER="$FILTER"'|^mem\.(available|committed|writeback)$'
FILTER="$FILTER"'|^ipv4\.(tcpsock|tcpopens|tcperrors|tcphandshake|sockstat_tcp_mem|sockstat_tcp_sockets|tcppackets|udppackets|udperrors)$'
FILTER="$FILTER"'|^disk\.|^disk_ops\.|^disk_util\.|^disk_await\.|^disk_backlog\.|^disk_svctm\.|^disk_qops\.'
FILTER="$FILTER"'|^app\.cardano'

CHARTS=$(curl -s "$ND/api/v1/charts" | jq -r '.charts|keys[]' | grep -E "$FILTER" | sort)

{
for w in $WINDOWS; do
  L=${w%%@*}; R=${w#*@}
  S=${R%@*}; E=${R#*@}
  A=$(date -u -d "$S" +%s); B=$(date -u -d "$E" +%s)
  for c in $CHARTS; do
    curl -s "$ND/api/v1/data?chart=$c&after=$A&before=$B&format=json&options=seconds" \
    | jq -r --arg w "$L" --arg h "$HOST" --arg c "$c" '
        (.labels // []) as $l
        | (.data // [])[]
        | . as $r
        | range(1; ($l|length))
        | select($r[.] != null)
        | [$w, $h, $c, ($l[.]|gsub(",";";")), $r[0], $r[.]]
        | @csv' 2>/dev/null
  done
done
} | gzip -9
