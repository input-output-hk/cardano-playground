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
# Cardinality policy. The indexed labels are service, ns, sev, kind, event, name,
# thread, and voterId on cast votes only; each is deliberately indexed for Explore
# performance and each is bounded by something structural -- a fixed vocabulary in
# the node, or the pools one node votes for.
#
# What must never be labelled is anything bounded by the chain instead: rbHash and
# ebHash are one value per block, voterId across the whole committee is one per
# seat and reassigned every epoch, and stack is unbounded. Those stay in the line
# for query-time `| json`, which also keeps them off the derived counters, since
# stage.metrics inherits whatever labels are set when it runs.
#
# host is not labelled because it duplicates the base instance label.
#
# Before adding a label, name the thing that bounds it. If the answer involves the
# committee, the chain, or a peer connection, it belongs in the body.
#
# Both tx-generator modules are always present but DORMANT unless their unit is
# running, so an environment can switch centrifuge<->firehose (or neither) with
# no config change. Today playground runs cardano-tx-centrifuge.service.
#
# Loki-derived counters are named leios_logmetrics_{,leios_,call_}* per service.
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
        // Export the leios_logmetrics_* counters derived below.  The base
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
            regex         = "leios_logmetrics_.*"
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

        // Wiring: node chain (node -> voting -> diffusion -> call -> write) + tx
        // modules. The single terminal write per line is loki.write.default (base
        // pipeline).
        //
        // This chain is duplicated in the leios-observability source's own
        // alloy.template for proto-devnet. A module added there is shipped here by
        // the pin and imported by the directory import above, but it stays inert
        // until it is also forwarded to here: an unwired `declare` is never
        // instantiated, emits nothing, and logs no error. Add modules in both
        // places.
        mod.cardano_node_process "node" {
          forward_to = [mod.leios_voting_process.vote.receiver]
        }

        mod.leios_voting_process "vote" {
          forward_to = [mod.leios_diffusion_process.diffusion.receiver]
        }

        mod.leios_diffusion_process "diffusion" {
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
