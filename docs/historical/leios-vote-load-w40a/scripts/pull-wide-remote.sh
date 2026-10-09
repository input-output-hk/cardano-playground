#!/usr/bin/env bash
# Runs ON a cluster host. Streams gzipped tidy-long rows of netdata's native-resolution
# data for the load-test windows to stdout.
#
#   window,host,chart,dimension,unix_time,value
#
# No `points` parameter is sent, so each chart comes back at its own collection
# interval (1s for most, 2s for the PSI charts, 5s for system.load) rather than being
# resampled to a common grid. Check the timestamps, do not assume 1s.
set -uo pipefail
HOST=$(hostname)
ND=localhost:19999

WINDOWS="${WIN_ONLY:-base_11:10:05:11:05 base_13:12:05:13:05 load1:14:05:15:05 load2:16:05:17:05 load3:18:05:19:05}"

# Chart families worth keeping for this investigation. Deliberately wide: netdata's
# 1s tier expires in ~96h and a second pull after that is impossible.
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
  L=${w%%:*}; R=${w#*:}
  S=$(echo "$R" | cut -d: -f1-2); E=$(echo "$R" | cut -d: -f3-4)
  A=$(date -u -d "2026-10-09T$S:00Z" +%s); B=$(date -u -d "2026-10-09T$E:00Z" +%s)
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
