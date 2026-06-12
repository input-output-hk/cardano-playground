---
name: monitoring-query
description: Query the cardano-playground Grafana Loki (logs) and Mimir (metrics) datasources directly via the Grafana datasource proxy API for cluster log/metric analysis. Use when investigating node behavior, forks, log events, or metrics on playground-monitored environments (leios, etc.) instead of asking the user for manual Grafana exports.
---

# Querying playground monitoring (Loki logs + Mimir metrics) from the CLI

## Access

- Grafana base URL: `https://playground.monitoring.aws.iohkdev.io`
- Auth: Grafana service-account token (Viewer role), sent as `Authorization: Bearer <token>`.
  The token is sops-age encrypted in the cardano-playground repo at `secrets/ai/monitoring-service-account`.
  Decrypt with the agent age identity — never print the token:
  `TOKEN=$(SOPS_AGE_KEY_FILE=~/.age-ai/credentials nix shell nixpkgs#sops -c sops -d <repo>/secrets/ai/monitoring-service-account)`
  Other agent secrets live in the same `secrets/ai/` directory.
- No tunnel needed: token auth bypasses the Google OAuth2 login path.
- Datasource UIDs (list with `GET /api/datasources`): `loki` (Loki), `mimir` (Prometheus/Mimir), `alertmanager_mimir`.

## Loki query pattern

```sh
TOKEN=$(cat <token-file>)
URL="https://playground.monitoring.aws.iohkdev.io/api/datasources/proxy/uid/loki/loki/api/v1/query_range"
START=$(date -u -d '2026-06-11T03:27:00Z' +%s)000000000   # nanosecond epoch
END=$(date -u -d '2026-06-11T03:28:40Z' +%s)000000000
curl -sfG -H "Authorization: Bearer $TOKEN" "$URL" \
  --data-urlencode 'query={environment="leios", systemd_unit="cardano-node.service", instance=~"leios.-(bp|rel).*"} |~ "AddedToCurrentChain|SwitchedToAFork"' \
  --data-urlencode "start=$START" --data-urlencode "end=$END" \
  --data-urlencode "limit=2000" --data-urlencode "direction=forward"
```

## Log formats: JSON vs human-readable — detect before parsing

Node log format is a per-host tracer-config choice (`Stdout MachineFormat` = JSON vs
`Stdout HumanFormat*` = text) and **may change at any redeploy**. Currently only `leios` and a
few select environments emit JSON; most are human-readable. Never assume — sample one line
first:

```sh
... | jq -r '.data.result[0].values[0][1]' | head -c 120
# starts with '{' → JSON (MachineFormat); otherwise human-readable
```

Loki **line filters** (`|=`, `|~`, `!=`) are plain substring/regex and work identically on both
formats — namespaces, trace kinds, hashes, and hostnames appear in the text either way, so the
query side of this skill is format-agnostic. Only the *extraction* step differs.

Unpack — JSON-format hosts (each value is `[ts, logline]`, logline is a JSON object):

```sh
... | jq -r '[.data.result[].values[][1]] | .[]' \
    | jq -rc '[.at, .host, (.data.kind // .ns), ((.data.newtip // .data.block // "") | tostring | .[0:60])] | join(" | ")' \
    | sort -u
```

Unpack — human-readable hosts. Verified shape (HumanFormatColoured, note leading ANSI color
escapes): `ESC[34m[timestamp][host:Namespace.Path](Severity,thread)ESC[0m message…`

```sh
... | jq -r '[.data.result[].values[][1]] | .[]' \
    | sed -E $'s/\x1b\\[[0-9;]*m//g; s/^\\[([^]]+)\\]\\[([^:]+):([^]]+)\\]\\(([^,]+),[0-9]+\\) /\\1 | \\2 | \\3 | \\4 | /' \
    | sort -u
# → "2026-06-12 17:47:35.0075Z | dijkstra1-bp-a-1 | ChainDB.AddBlockEvent.AddedToCurrentChain | Notice | Chain extended, new tip: …"
```

(Always strip ANSI first — the color codes otherwise break anchored regexes and column tools.)

For mixed-format result sets (cross-environment queries), split on the leading `{` and run each
half through its parser, or fall back to grep-level analysis (counts, timestamps, hash
occurrences) which needs no parsing at all. If a recipe that worked before suddenly returns
nothing through `jq`, re-check the format — it may have changed under you.

Run `jq` via `nix shell nixpkgs#jq -c sh -c '...'` if not on PATH. Always `sort` output: Loki returns
per-stream batches, not globally time-ordered lines. Pipe long output to a file first and post-filter, rather than re-querying.

## Label schema (cardano-playground clusters)

- `environment` — cluster name; discover current values via
  `GET .../loki/api/v1/label/environment/values` (as of 2026-06-12: buildkite, dijkstra, leios,
  mainnet, misc, preprod, preview, sanchonet; leios was JSON-format, dijkstra human-format —
  re-sample, don't trust this snapshot)
- `instance` — host, e.g. `leios2-bp-b-1`, `leios1-rel-a-1` (pattern: `<env><group>-<role>-<az>-<n>`)
- `group` — e.g. `leios1`
- `systemd_unit` — e.g. `cardano-node.service`
- `syslog_identifier` — e.g. `cardano-node-start`

## Useful line filters for cardano-node (new tracing system)

- Chain selection: `|~ "AddedToCurrentChain|SwitchedToAFork|TrySwitchToAFork|IgnoreBlock"`
- Forging: `|~ "TraceNodeIsLeader|TraceForgedBlock|TraceAdoptedBlock"`
- Leios: `|~ "LeiosBlockForged|LeiosBlockStored|LeiosBlockAcquired|LeiosBlockPointMissing|LeiosVoted|LeiosVoteAcquired"`
- Track one block: `|= "<hash-prefix>"` across `{environment="leios"}` with NO instance filter
  (other services — dbsync, centrifuge, faucet hosts — also run nodes and see blocks).
- Exclude noise: `!= "StateQueryServer" != "RequestNext" != "StartLeadershipCheck"`

Caveat: at this cluster's default severities there are NO `ChainSync.*` / `BlockFetch.*` traces —
block transfer is only observable indirectly via `ChainDB.AddBlockEvent.*` on the receiver and
`Forge.*` on the producer. Absence of a hash in logs ≠ absence of transfer attempts.

## Mimir (metrics) query pattern

```sh
curl -sfG -H "Authorization: Bearer $TOKEN" \
  "https://playground.monitoring.aws.iohkdev.io/api/datasources/proxy/uid/mimir/api/v1/query_range" \
  --data-urlencode 'query=cardano_node_metrics_blockNum_int{environment="leios"}' \
  --data-urlencode "start=$(date -u -d '...' +%s)" --data-urlencode "end=$(date -u -d '...' +%s)" \
  --data-urlencode "step=15"
```

Mimir start/end are SECONDS (not ns). Metrics scrape interval is 1 minute — use `step=60`;
treat ±1-sample skew across hosts as scrape jitter.

Discover the full metric scope per host (~400 series) via:
`.../api/v1/series --data-urlencode 'match[]={__name__=~".+", instance="<host>"}'` (plus start/end).

Key cardano-node metric names (new tracing system, `cardano_node_metrics_` prefix):
- `blockNum_int`, `slotNum_int`, `density_real` — chain tip per instance; pivot per-host over time
  to map forks/stalls/islands.
- `blockfetchclient_blockdelay_real` — delay of the LAST completed block fetch; if it freezes at a
  constant while others move, that node's BlockFetch client is wedged (smoking gun for one-way
  protocol stalls). Also `blockfetchclient_lateblocks_counter`, `_blocksize_int`.
- `ChainSync_HeadersServed_counter`, `served_header_counter`, `served_block_counter` — server-side
  serving activity (proves the other direction of a connection is alive).
- `peerSelection_Hot_int` / `_Warm_int` / `_Cold_int` (+ `*Promotions/Demotions`) — peer state machine.
- `connectionManager_*`, `Forge_*` (incl. Leios `Forge_endorser_block_*`), `Mempool_*`, `blockperf_*`.

## Gotchas

- Loki caps `limit` (5000); narrow the time window or add filters rather than paginating blindly.
- `direction=forward` for chronological investigation.
- Slot-to-wallclock on the leios devnet: 1 slot = 1 s; derive offset from any log line that has both
  (`Forge.Loop.StartLeadershipCheck` logs slot + timestamp).
- Grafana-UI JSON exports wrap lines as `[{line: "<json-string>", ...}]` — prefer direct API queries.
