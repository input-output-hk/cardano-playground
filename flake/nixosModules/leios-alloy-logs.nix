# nixosModule: leios-alloy-logs
#
# Cardinality-bounded leios alloy log pipeline for the leios dashboards, built
# from per-service Alloy `declare` MODULES (Pattern B: fan-out + drop-first at
# the service boundary; the node sub-facets voting/call-trace are chained so each
# node line is written exactly once).
#
# The five enrichment modules are the SHARED source of truth, imported via
# import.file from the leios-observability flake input
# (ouroboros-leios demo/proto-devnet/config/alloy-modules/*.alloy) -- the SAME files the
# ouroboros-leios proto-devnet stack uses. Only the FRONT-END below differs per
# environment: here it routes the cardano-parts journald source by `systemd_unit`
# and stamps the routing `service` label; proto-devnet tails process-compose
# files and routes by `process`. Everything downstream is shared.
#
# The base cardano-parts profile-grafana-alloy journal pipeline already ships one
# raw systemd_unit-labelled copy to loki.write.default and hands each line (body
# = the raw trace JSON) to loki.process.leios_route via extraJournalReceivers, so
# this side needs no raw write and no envelope unwrap.
#
# Cardinality budget (measured on the live 15-node fleet), all deliberately
# indexed for Explore performance:
#   service/type ~4, ns ~56 (stable), sev ~5, kind ~50-150, voterId ~3,
#   event 2, name ~tens, thread ~few (named threads)  -- all bounded.
#   host: NOT labelled (== base instance); rbHash/stack NEVER labelled -- they
#   stay in the line for query-time `| json`, which keeps them off the counters.
#
# Both tx-generator modules are always present but DORMANT unless their unit is
# running, so an environment can switch centrifuge<->firehose (or neither) with
# no config change. Today playground runs cardano-tx-centrifuge.service.
#
# Loki-derived counters are named cardano_node_metrics_loki_{leios,call,txgen}_*.
{inputs, ...}: {
  flake.nixosModules.leios-alloy-logs = {
    config,
    name,
    ...
  }: let
    groupCfg = config.cardano-parts.cluster.group;
    inherit (groupCfg.meta) environmentName;
    inherit (groupCfg) groupName;

    # Shared alloy enrichment modules, pinned independently of the node version.
    # builtins.path narrows the node closure to just the module files -- the
    # leios-observability input tree as a whole is NOT deployed to nodes.
    leiosAlloyModules = builtins.path {
      path = "${inputs.leios-observability}/demo/proto-devnet/config/alloy-modules";
      name = "leios-alloy-modules";
    };
  in {
    # Place the shared modules at a discoverable /etc path instead of a bare nix
    # store path. A SUBDIR of /etc/alloy is safe: alloy loads *.alloy from
    # /etc/alloy ignoring subdirs, so these are not auto-loaded as top-level
    # config -- only imported explicitly via import.file below.
    #
    # Placed PER-FILE (not `.source = <dir>`) on purpose: a whole-dir `.source`
    # makes /etc/alloy/leios-modules a SYMLINK, and alloy's directory import.file
    # does NOT traverse a symlinked directory (fails at runtime with "custom
    # component ... not found in the registry"). Per-file entries make
    # /etc/alloy/leios-modules a real directory of file-symlinks, which imports fine.
    environment.etc = builtins.listToAttrs (
      map (f: {
        name = "alloy/leios-modules/${f}";
        value.source = "${leiosAlloyModules}/${f}";
      }) (
        builtins.filter (f: builtins.match ".*[.]alloy$" f != null)
        (builtins.attrNames (builtins.readDir leiosAlloyModules))
      )
    );

    services.alloy = {
      extraJournalReceivers = ["loki.process.leios_route.receiver"];

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

        // FRONT-END (environment-specific): route the journald source by
        // systemd_unit and stamp the routing `service` label, then fan to the
        // shared modules. cardano-tracer.service is excluded (double-journals
        // forwarded traces); multi-instance cardano-node-N is matched. Non-node/tx
        // units are dropped up front, so every forwarded line carries a `service`.
        // No raw write / no unwrap -- the base journal pipeline handles the raw
        // copy and the journal message is already the trace JSON.
        loki.process "leios_route" {
          stage.match {
            selector = `{systemd_unit!~"cardano-node(-[0-9]+)?\\.service|cardano-tx-centrifuge\\.service|cardano-tx-firehose\\.service"}`
            action   = "drop"
          }

          stage.match {
            selector = `{systemd_unit=~"cardano-node(-[0-9]+)?\\.service"}`
            stage.static_labels {
              values = {service = "cardano-node"}
            }
          }

          stage.match {
            selector = `{systemd_unit="cardano-tx-centrifuge.service"}`
            stage.static_labels {
              values = {service = "tx-centrifuge"}
            }
          }

          stage.match {
            selector = `{systemd_unit="cardano-tx-firehose.service"}`
            stage.static_labels {
              values = {service = "tx-firehose"}
            }
          }

          forward_to = [
            mod.cardano_node_process.node.receiver,
            mod.tx_firehose_process.firehose.receiver,
            mod.tx_centrifuge_process.centrifuge.receiver,
          ]
        }

        // Shared per-service enrichment modules (import.file from the pinned
        // leios-observability source; directory import exposes each file's
        // `declare` under this `mod` namespace). Its store path lands in the
        // system closure, so the files are on the host for import at runtime.
        import.file "mod" {
          filename = "/etc/alloy/leios-modules"
        }

        // Wiring: node chain (node -> voting -> call -> write) + tx modules. The
        // single terminal write per line is loki.write.default (base pipeline).
        mod.cardano_node_process "node" {
          forward_to = [mod.leios_voting_process.vote.receiver]
        }

        mod.leios_voting_process "vote" {
          forward_to = [mod.call_trace_process.call.receiver]
        }

        mod.call_trace_process "call" {
          forward_to = [loki.write.default.receiver]
        }

        mod.tx_firehose_process "firehose" {
          forward_to = [loki.write.default.receiver]
        }

        mod.tx_centrifuge_process "centrifuge" {
          forward_to = [loki.write.default.receiver]
        }
      '';
    };
  };
}
