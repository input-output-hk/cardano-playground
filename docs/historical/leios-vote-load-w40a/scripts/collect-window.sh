#!/usr/bin/env bash
# collect-window.sh <label> <HH:MM:SS end of a 1h window>
# Appends one "label<TAB>metric<TAB>value" row per metric to windows.tsv.
# Metric set is denominator-safe where it matters; see leios-vote-load-findings.md.
set -uo pipefail
Q=/tmp/claude-1001/-home-jlotoski-ai-share/354b7bb2-9514-4a1a-a403-520b9944b866/scratchpad/q.sh
TSV=/tmp/claude-1001/-home-jlotoski-ai-share/354b7bb2-9514-4a1a-a403-520b9944b866/scratchpad/windows.tsv
LABEL="$1"; END="$2"
T=$(date -u -d "2026-10-09T${END}Z" +%s)

pm() { $Q mimir query --data-urlencode "query=${2}((${1})[3600s:60s])" --data-urlencode "time=$T" 2>/dev/null \
        | jq -r '.data.result[0].value[1] // "NaN"'; }
lk() { $Q loki  query --data-urlencode "query=$1" --data-urlencode "time=$T" 2>/dev/null \
        | jq -r '.data.result[0].value[1] // "0"'; }
emit() { printf "%s\t%s\t%s\n" "$LABEL" "$1" "$2" >> "$TSV"; }

REL='instance=~"leios[0-9]-rel-.*"'
TX='instance:node_network_transmit_bytes_excluding_lo:rate5m'
RX='instance:node_network_receive_bytes_excluding_lo:rate5m'
MIB=0.00000095367431640625
ENV='environment="leios"'

sc() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.4f", a*b}'; }

emit votes_cast_per_min    "$(sc "$(pm "sum(rate(leios_logmetrics_leios_votes_cast_total{$ENV}[5m]))" avg_over_time)" 60)"
emit votes_acq_per_s_avg   "$(pm "avg(rate(leios_logmetrics_leios_votes_acquired_total{$ENV}[5m]))" avg_over_time)"
emit txgen_per_s           "$(pm "sum(rate(leios_logmetrics_txgen_submitted_total{$ENV}[5m]))" avg_over_time)"

emit relay_egress_total_mib "$(sc "$(pm "sum($TX{$REL})" avg_over_time)" $MIB)"
emit relay_egress_peak_mib  "$(sc "$(pm "max($TX{$REL})" max_over_time)" $MIB)"
emit relay_ingress_total_mib "$(sc "$(pm "sum($RX{$REL})" avg_over_time)" $MIB)"
emit relay_ingress_peak_mib  "$(sc "$(pm "max($RX{$REL})" max_over_time)" $MIB)"

emit relay_cpu_mean_cores  "$(pm "avg(rate(cardano_node_metrics_Stat_cputicks_int{$REL}[5m])/100)" avg_over_time)"
emit relay_cpu_peak_cores  "$(pm "max(rate(cardano_node_metrics_Stat_cputicks_int{$REL}[5m])/100)" max_over_time)"

# denominator-safe: announcement volume is the denominator, late is the numerator
emit eb_announce_per_s     "$(pm "sum(rate(leios_logmetrics_diffusion_announcement_age_seconds_count{$ENV}[10m]))" avg_over_time)"
emit eb_late_per_s         "$(pm "sum(rate(cardano_node_metrics_leios_eb_announcement_late_counter{$ENV}[10m]))" avg_over_time)"
emit eb_late_pct           "$(pm "100*sum(rate(cardano_node_metrics_leios_eb_announcement_late_counter{$ENV}[10m]))/sum(rate(leios_logmetrics_diffusion_announcement_age_seconds_count{$ENV}[10m]))" avg_over_time)"

# normalised: raw decline rate tracks vote volume and is not a strain signal
emit declines_per_1k_votes "$(pm "1000*sum(rate(leios_logmetrics_leios_votes_declined_total{$ENV}[10m]))/sum(rate(leios_logmetrics_leios_votes_cast_total{$ENV}[10m]))" avg_over_time)"

B='{environment="leios", instance="leios1-bp-a-1", systemd_unit="cardano-node.service"}'
R='{environment="leios", instance=~"leios[0-9]-rel-.*", systemd_unit="cardano-node.service"}'
emit ebs_certified_per_h   "$(lk "sum(count_over_time($B |= \"LeiosBlockCertified\" [1h]))/2")"
emit ebs_forged_per_h      "$(lk "sum(count_over_time($B |= \"LeiosBlockForged\" [1h]))/2")"
emit mux_remote_per_h      "$(lk "sum(count_over_time($R |= \"MuxErrored\" != \"127.0.0.1\" [1h]))/2")"
emit mux_loopback_per_h    "$(lk "sum(count_over_time($R |= \"MuxErrored\" |= \"127.0.0.1\" [1h]))/2")"
emit exceeded_tl_per_h     "$(lk "sum(count_over_time($R |= \"ExceededTimeLimit\" [1h]))/2")"

echo "collected $LABEL (1h ending ${END}Z)"
