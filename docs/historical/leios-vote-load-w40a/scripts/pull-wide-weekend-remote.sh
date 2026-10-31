#!/usr/bin/env bash
# Runs ON a cluster host. Streams gzipped tidy-long rows of netdata's native-resolution
# data for full ISO timestamp ranges, so it can span days.
#
#   window,host,chart,dimension,unix_time,value
#
# No `points` parameter is sent, so each chart comes back at its own collection interval
# (1s for most, 2s for PSI, 5s for system.load). Check timestamps, do not assume 1s.
#
# CHUNKS uses @ as the separator because ISO timestamps contain colons, and must be a
# single line because it is interpolated into a remote "for ...; do".
set -euo pipefail
HOST=$(hostname)
ND=localhost:19999

CHUNKS="${CHUNKS:-d09@2026-10-09T14:00:00Z@2026-10-10T00:00:00Z d10@2026-10-10T00:00:00Z@2026-10-11T00:00:00Z d11@2026-10-11T00:00:00Z@2026-10-12T00:00:00Z}"

FILTER='^net\.|^net_packets\.|^net_drops\.|^net_errors\.|^net_carrier\.'
FILTER="$FILTER"'|^system\.(cpu|load|io|ram|intr|ctxt|processes|processes_state|net|ipv4|uptime|softirqs|softnet_stat)$'
FILTER="$FILTER"'|^system\..*pressure'
FILTER="$FILTER"'|^mem\.(available|committed|writeback)$'
FILTER="$FILTER"'|^ipv4\.(tcpsock|tcpopens|tcperrors|tcphandshake|sockstat_tcp_mem|sockstat_tcp_sockets|tcppackets|udppackets|udperrors)$'
FILTER="$FILTER"'|^disk\.|^disk_ops\.|^disk_util\.|^disk_await\.|^disk_backlog\.|^disk_svctm\.|^disk_qops\.'
FILTER="$FILTER"'|^app\.cardano'

CHARTS=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 300 "$ND/api/v1/charts" | jq -r '.charts|keys[]' | grep -E "$FILTER" | sort)

{
for w in $CHUNKS; do
  L=${w%%@*}; R=${w#*@}
  S=${R%@*}; E=${R#*@}
  A=$(date -u -d "$S" +%s); B=$(date -u -d "$E" +%s)
  for c in $CHARTS; do
    curl --fail --silent --show-error --connect-timeout 10 --max-time 300 "$ND/api/v1/data?chart=$c&after=$A&before=$B&format=json&options=seconds" \
    | jq -r --arg w "$L" --arg h "$HOST" --arg c "$c" '
        if (.labels | type) != "array" or (.data | type) != "array"
           or (.labels | length) < 2 or (.data | length) == 0
        then error("missing Netdata labels/data") else . end
        | .labels as $l
        | .data[]
        | . as $r
        | range(1; ($l|length))
        | select($r[.] != null)
        | [$w, $h, $c, ($l[.]|gsub(",";";")), $r[0], $r[.]]
        | @csv'
  done
done
} | gzip -9
