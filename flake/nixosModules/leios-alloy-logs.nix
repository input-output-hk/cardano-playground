# nixosModule: leios-alloy-logs
#
# Cardinality-bounded leios alloy log pipeline (single-write enrichment) for
# the leios dashboards.  Adapted from the ouroboros-leios proto-devnet x-ray
# pipeline (demo/proto-devnet/config/alloy.template) to the journald source the
# cardano-parts profile-grafana-alloy module ships.
#
# Strategy: parse each cardano-node / tx-centrifuge journal line once and write
# it once to loki.write.default carrying kind/ns/sev/service labels, so every
# kind is label-filterable in Explore without `| json`.  The vote/call
# enrichment is folded in as nested stage.match blocks with a single terminal
# forward_to -- fanning to loki.write.default from multiple processors would
# otherwise re-write the whole Debug-level trace volume ~3x.  The cardano-parts
# base journal pipeline still ships one raw systemd_unit-labelled copy.
#
# Cardinality budget (measured on the live 15-node fleet), all deliberately
# indexed for Explore performance:
#   service/type ~4, ns ~56 (stable), sev ~5, kind ~50-150, voterId ~3,
#   event 2, name ~tens, thread ~few (named threads)  -- all bounded.
#   host: NOT labelled -- duplicates the base `instance` label.
#   rbHash (voting, ~one per block) and stack (call-trace call path, grows with
#     the call graph -- higher-card once enabled fleet-wide): left in the line
#     for query-time `| json` (vote_rbHash / stack), which keeps them off the
#     counters too.
#
# Loki-derived counters are named cardano_node_metrics_loki_{leios,call}_* to
# group with the node-metrics family while flagging loki provenance, and are
# bounded because the unbounded fields above are never labelled.  Metrics come
# from the base integrations/cardano-node scrape (environment="leios").
_: {
  flake.nixosModules.leios-alloy-logs = {
    config,
    name,
    ...
  }: let
    groupCfg = config.cardano-parts.cluster.group;
    environmentName = groupCfg.meta.environmentName;
    groupName = groupCfg.groupName;
  in {
    services.alloy = {
      extraJournalReceivers = ["loki.process.leios_extract_logs.receiver"];

      extraAlloyConfig = ''
        // Export the cardano_node_metrics_loki_* counters derived below.  The base
        // profile's integrations_alloy scrape uses prometheus.exporter.self which
        // does not expose loki.process metrics with a keep-regex, so it will not
        // carry these.  Scrape alloy's own /metrics, keep ONLY our derived series,
        // and tag them with this node's instance/environment/group so per-node
        // counters disaggregate in Mimir.
        prometheus.scrape "leios_alloy_pipeline_metrics" {
          targets = [{
            __address__ = "127.0.0.1:12345",
            instance    = "${name}",
            environment = "${environmentName}",
            group       = "${groupName}",
          }]

          forward_to = [prometheus.relabel.leios_alloy_pipeline_metrics.receiver]
          job_name   = "integrations/leios-alloy-pipeline"
        }

        prometheus.relabel "leios_alloy_pipeline_metrics" {
          forward_to = [prometheus.remote_write.integrations.receiver]

          rule {
            source_labels = ["__name__"]
            regex         = "cardano_node_metrics_loki_.*"
            action        = "keep"
          }
        }

        // Single enrichment pipeline: parse once, label everything, write once.
        loki.process "leios_extract_logs" {
          // Route: keep only the units that emit machine-format leios traces.
          // cardano-tracer.service is excluded (it journals the same forwarded
          // traces a second time); multi-instance cardano-node-N.service matched.
          stage.match {
            selector = `{systemd_unit!~"cardano-node(-[0-9]+)?\\.service|cardano-tx-centrifuge\\.service"}`
            action   = "drop"
          }

          // Pull kind straight from data.kind so it can be labelled on every line.
          stage.json {
            expressions = {
              at   = "at",
              sev  = "sev",
              ns   = "ns",
              kind = "data.kind",
              data = "data",
            }
            drop_malformed = true
          }

          stage.timestamp {
            source = "at"
            format = "RFC3339"
          }

          // Indexed labels applied to ALL lines (bounded; drive fast Explore).
          // `host` intentionally omitted -- it equals the base `instance` label.
          stage.labels {
            values = {
              level = "sev",
              sev   = "sev",
              ns    = "ns",
              kind  = "kind",
            }
          }

          stage.static_labels {
            values = {
              service = "cardano-node",
              type    = "cardano-node",
            }
          }

          stage.match {
            selector = `{systemd_unit="cardano-tx-centrifuge.service"}`
            stage.static_labels {
              values = {
                service = "tx-centrifuge",
                type    = "tx-centrifuge",
              }
            }
          }

          // Emit the decoded 'data' object as the line body so query-time `| json`
          // sees kind/vote/event/etc, at the top level (rbHash -> vote_rbHash,
          // thread, ...).
          stage.output {
            source = "data"
          }

          // --- Voting enrichment (inline; no extra write) ---
          // rbHash deliberately NOT extracted/labelled -- it stays in the line for
          // `| json` (field vote_rbHash) and off the counters, keeping them bounded.
          // voterId (~3) is the only variable label the counters inherit.
          stage.match {
            selector = `{kind=~"LeiosVoted|LeiosVoteAcquired"}`

            stage.json {
              expressions = {
                voterId = "vote.voterId",
              }
              drop_malformed = true
            }

            stage.static_labels {
              values = {
                service = "leios-voting",
                type    = "leios-voting",
              }
            }

            stage.labels {
              values = {
                voterId = "voterId",
              }
            }

            stage.match {
              selector = `{kind="LeiosVoted"}`

              stage.json {
                expressions = {
                  weight = "weight",
                }
              }

              stage.metrics {
                metric.counter {
                  name              = "voted_weight_total"
                  description       = "The total accumulated voting weight"
                  prefix            = "cardano_node_metrics_loki_leios_"
                  action            = "add"
                  source            = "weight"
                  max_idle_duration = "24h"
                }
              }
            }

            stage.match {
              selector = `{kind="LeiosVoteAcquired"}`

              stage.metrics {
                metric.counter {
                  name              = "votes_acquired_total"
                  description       = "The total votes acquired"
                  prefix            = "cardano_node_metrics_loki_leios_"
                  action            = "inc"
                  match_all         = true
                  max_idle_duration = "24h"
                }
              }
            }
          }

          // --- Call-trace enrichment (inline; active in proto-devnet, coming to Musashi) ---
          // stack deliberately NOT extracted/labelled -- it is the call path (many
          // combinations, grows with the call graph); stays in the line for `| json`.
          // thread is a named, low-cardinality thread, so it is indexed instead.
          stage.match {
            selector = `{kind="Call"}`

            stage.json {
              expressions = {
                event  = "event",
                name   = "name",
                thread = "thread",
              }
              drop_malformed = true
            }

            stage.static_labels {
              values = {
                service = "leios-call-trace",
                type    = "leios-call-trace",
              }
            }

            stage.labels {
              values = {
                event  = "event",
                name   = "name",
                thread = "thread",
              }
            }

            stage.match {
              selector = `{event="Start"}`

              stage.metrics {
                metric.counter {
                  name              = "started_total"
                  description       = "Total started calls"
                  prefix            = "cardano_node_metrics_loki_call_"
                  action            = "inc"
                  match_all         = true
                  max_idle_duration = "24h"
                }
              }
            }

            stage.match {
              selector = `{event="End"}`

              stage.json {
                expressions = {
                  duration    = "duration",
                  allocations = "allocations",
                  result      = "result",
                }
                drop_malformed = true
              }

              stage.metrics {
                metric.counter {
                  name              = "ended_total"
                  description       = "Total ended calls"
                  prefix            = "cardano_node_metrics_loki_call_"
                  action            = "inc"
                  match_all         = true
                  max_idle_duration = "24h"
                }

                metric.counter {
                  name              = "duration_total"
                  description       = "Total call duration"
                  prefix            = "cardano_node_metrics_loki_call_"
                  action            = "add"
                  source            = "duration"
                  max_idle_duration = "24h"
                }

                metric.counter {
                  name              = "allocations_total"
                  description       = "Total call allocations"
                  prefix            = "cardano_node_metrics_loki_call_"
                  action            = "add"
                  source            = "allocations"
                  max_idle_duration = "24h"
                }
              }
            }
          }

          // The only write: one enriched copy per line.
          forward_to = [loki.write.default.receiver]
        }
      '';
    };
  };
}
