#!/usr/bin/env nu
# Query Delegated Stake for Playground Pools and DRep
#
# Discovers pools from secrets/groups/<env>N/no-deploy/*-pool.id and the DRep
# from secrets/envs/<env>/drep/, then queries the chain for delegated stake.
#
# ENVIRONMENT VARIABLES (provided by the playground devShell):
#   TESTNET_MAGIC            Cardano testnet magic number
#   CARDANO_NODE_SOCKET_PATH Path to the running cardano-node socket
#   CARDANO_NODE_NETWORK_ID  Network ID (mirrors TESTNET_MAGIC)
#   DEBUG                    When set (any value), print commands before execution
#
# USAGE (run from repo root inside the devShell):
#   query-delegation.nu [env]
#   query-delegation.nu preview
#   query-delegation.nu preprod
#   DEBUG=1 query-delegation.nu preview
# ─── SOPS helpers ─────────────────────────────────────────────────────────────
def sops-config [file: string] {
  mut dir = if ($file | str starts-with '/') {
    $file | path dirname
  } else {
    [
      $env.PWD
      ($file | path dirname)
    ] | path join
  }
  loop {
    if ($"($dir)/.sops.yaml" | path exists) { return $"($dir)/.sops.yaml" }
    let parent = ($dir | path dirname)
    if $parent == $dir {
      error make --unspanned {
        msg: $"No .sops.yaml found above ($file)"
      }
    }
    $dir = $parent
  }
}
def sops-decrypt [file: string] {
  let config = (sops-config $file)
  debug-cmd "sops" [
    "--config"
    $config
    "--input-type"
    "binary"
    "--output-type"
    "binary"
    "--decrypt"
    $file
  ]
  ^sops --config $config --input-type binary --output-type binary --decrypt $file
}
# ─── Debug helper ─────────────────────────────────────────────────────────────
def is-debug [] { ("DEBUG" in $env) and ($env.DEBUG | is-not-empty) }
# Print the command that is about to be run when DEBUG is set
def debug-cmd [cmd: string, args: list<string>] {
  if (is-debug) {
    print $"(ansi cyan_dimmed)  + ($cmd) ($args | str join ' ')(ansi reset)"
  }
}
# ─── Display helpers ──────────────────────────────────────────────────────────
def comma-sep [n: int] {
  let chars = ($n | into string | split chars)
  let len = ($chars | length)
  if $len <= 3 { return ($chars | str join) }
  mut result = ""
  for i in 0..<$len {
    let pos = ($len - $i)
    if $i > 0 and ($pos mod 3) == 0 {
      $result = $"($result),"
    }
    $result = $"($result)($chars | get $i)"
  }
  $result
}
def lovelace-to-ada [lovelace: int] {
  let whole = ($lovelace // 1_000_000)
  let frac = ($lovelace mod 1_000_000)
  let frac_padded = ($frac | into string | fill --width 6 --character '0' --alignment right)
  $"(comma-sep $whole).($frac_padded) ADA"
}
# ─── Environment helpers ─────────────────────────────────────────────────────
def expected-magic [environment: string] { match $environment {
  "preview" => "2"
  "preprod" => "1"
  "dijkstra" => "6"
  "leios" => "164"
  "sanchonet" => "4"
  _ => null
} }
def resolve-env [environment?: string] {
  if $environment != null {
    $environment
  } else if ("ENV" in $env) {
    $env.ENV
  } else {
    error make --unspanned {msg: "Provide an <environment> argument or set the ENV environment variable"}
  }
}
def check-network [environment: string] {
  let expected = (expected-magic $environment)
  if $expected == null { return }
  for var in ["TESTNET_MAGIC", "CARDANO_NODE_NETWORK_ID"] {
    if ($var in $env) and ($env | get $var | into string) != $expected {
      error make --unspanned {
        msg: $"($var) is ($env | get $var) but expected ($expected) for ($environment)"
      }
    }
  }
}
def net-args [] {
  if ("TESTNET_MAGIC" not-in $env) {
    error make --unspanned {msg: "TESTNET_MAGIC is not set. Are you inside the playground devShell?"}
  }
  [
    "--testnet-magic"
    $env.TESTNET_MAGIC
  ]
}
def check-node-synced [environment: string, net_args: list<string>] {
  let tip_json = try {
    debug-cmd "cardano-cli" (["latest", "query", "tip"] | append $net_args)
    ^cardano-cli latest query tip ...$net_args | from json
  } catch {
    error make --unspanned {msg: "Cannot connect to cardano-node. Is the node running and CARDANO_NODE_SOCKET_PATH set?"}
  }
  let sync_pct = ($tip_json | get syncProgress | into float)
  if $sync_pct < 100.0 {
    error make --unspanned {
      msg: $"Node is only ($sync_pct)% synced on ($environment). Wait for 100% before querying."
    }
  }
  $tip_json
}
# ─── Discovery ───────────────────────────────────────────────────────────────
# Find group directories matching an environment prefix (e.g., preview → [preview1, preview2, preview3])
def find-groups [environment: string] {
  let groups_dir = "secrets/groups"
  if not ($groups_dir | path exists) { return [] }
  ls $groups_dir | where type == dir | each { |d| $d.name | path basename } | where { |name| $name =~ $"^($environment)\\d+$" } | sort
}
# Find pool.id files in a group's no-deploy directory
def find-pool-id-files [group: string] {
  let nd = $"secrets/groups/($group)/no-deploy"
  if not ($nd | path exists) { return [] }
  glob $"($nd)/*-pool.id" | sort
}
# ─── Query functions ─────────────────────────────────────────────────────────
def query-pool-stake [pool_id: string, net_args: list<string>] {
  debug-cmd "cardano-cli" (["latest", "query", "stake-snapshot", "--stake-pool-id", $pool_id] | append $net_args)
  let data = (^cardano-cli latest query stake-snapshot --stake-pool-id $pool_id ...$net_args | from json)
  # Pool stake is nested under pools.<hex-key-hash>; extract the first (only) entry
  let pool_data = (
    $data | get pools | transpose _hash info | first | get info
  )
  {
    mark: ($pool_data | get -o stakeMark | default 0)
    set: ($pool_data | get -o stakeSet | default 0)
    go: ($pool_data | get -o stakeGo | default 0)
  }
}
def query-drep-info [vkey_path: string, net_args: list<string>] {
  let f_vkey = (^mktemp --suffix .vkey | str trim)
  try {
    sops-decrypt $vkey_path | save --force $f_vkey
    debug-cmd "cardano-cli" [
      "latest"
      "governance"
      "drep"
      "id"
      "--drep-verification-key-file"
      $f_vkey
    ]
    let drep_id = (^cardano-cli latest governance drep id --drep-verification-key-file $f_vkey | str trim)
    debug-cmd "cardano-cli" ([
      "latest"
      "query"
      "drep-state"
      "--drep-verification-key-file"
      $f_vkey
      "--include-stake"
    ] | append $net_args)
    let state = (^cardano-cli latest query drep-state --drep-verification-key-file $f_vkey --include-stake ...$net_args | from json)
    rm --force $f_vkey
    if ($state | is-empty) {
      return {
        drep_id: $drep_id
        stake: 0
        expiry: null
      }
    }
    let info = ($state | first | get 1)
    {
      drep_id: $drep_id
      stake: ($info | get -o stake | default 0)
      expiry: ($info | get -o expiry | default null)
    }
  } catch {|e|
    rm --force $f_vkey
    error make --unspanned {
      msg: $"Failed to query DRep: ($e.msg)"
    }
  }
}
# ─── Network-wide distribution queries ───────────────────────────────────────
# Query DRep stake distribution and state for network-wide totals
def query-drep-totals [epoch: int, net_args: list<string>] {
  # drep-stake-distribution includes expired dreps and system dreps (alwaysAbstain, alwaysNoConfidence)
  debug-cmd "cardano-cli" (["latest", "query", "drep-stake-distribution", "--all-dreps"] | append $net_args)
  let drep_dist = (^cardano-cli latest query drep-stake-distribution --all-dreps ...$net_args | from json)
  let dist_entries = ($drep_dist | transpose key value)
  let always_abstain = (
    $dist_entries | where key == "drep-alwaysAbstain" | get -o value | safe-sum
  )
  let always_noconf = (
    $dist_entries | where key == "drep-alwaysNoConfidence" | get -o value | safe-sum
  )
  let stake_total = ($dist_entries | get value | safe-sum)
  # drep-state with --include-stake gives per-drep expiry and stake (excludes system dreps)
  debug-cmd "cardano-cli" (["latest", "query", "drep-state", "--all-dreps", "--include-stake"] | append $net_args)
  let drep_state = (^cardano-cli latest query drep-state --all-dreps --include-stake ...$net_args | from json)
  let active_stake = (
    $drep_state | where { |e| ($e | get 1 | get -o expiry | default 0) >= $epoch } | each { |e| $e | get 1 | get -o stake | default 0 } | safe-sum
  )
  let expired_stake = (
    $drep_state | where { |e| ($e | get 1 | get -o expiry | default 0) < $epoch } | each { |e| $e | get 1 | get -o stake | default 0 } | safe-sum
  )
  let active_count = ($drep_state | where { |e| ($e | get 1 | get -o expiry | default 0) >= $epoch } | length)
  let expired_count = ($drep_state | where { |e| ($e | get 1 | get -o expiry | default 0) < $epoch } | length)
  {
    stake_total: $stake_total
    active_stake: $active_stake
    expired_stake: $expired_stake
    always_abstain: $always_abstain
    always_noconf: $always_noconf
    active_count: $active_count
    expired_count: $expired_count
  }
}
# Query SPO stake distribution for network-wide totals
def query-pool-totals [net_args: list<string>] {
  debug-cmd "cardano-cli" (["latest", "query", "spo-stake-distribution", "--all-spos"] | append $net_args)
  let pool_dist = (^cardano-cli latest query spo-stake-distribution --all-spos ...$net_args | from json)
  let stake_total = ($pool_dist | each { |e| $e | get 1 } | safe-sum)
  let abstain_total = (
    $pool_dist | where { |e| ($e | get -o 2) == "drep-alwaysAbstain" } | each { |e| $e | get 1 } | safe-sum
  )
  let noconf_total = (
    $pool_dist | where { |e| ($e | get -o 2) == "drep-alwaysNoConfidence" } | each { |e| $e | get 1 } | safe-sum
  )
  let pool_count = ($pool_dist | length)
  {
    stake_total: $stake_total
    abstain_total: $abstain_total
    noconf_total: $noconf_total
    pool_count: $pool_count
  }
}
# Safe sum that returns 0 for empty lists (nushell's math sum fails on empty input)
def safe-sum [] { if ($in | is-empty) { 0 } else { $in | math sum } }
# Format a percentage with 4 decimal places
def pct [numerator: int, denominator: int] {
  if $denominator == 0 { return "0.0000%" }
  let result = (($numerator | into float) / ($denominator | into float) * 100 | math round --precision 4)
  $"($result)%"
}
# Convert a protocol parameter threshold (number or {numerator, denominator}) to a percentage string
def threshold-pct [val] {
  let pct_val = if ($val | describe | str starts-with 'record') {
    let num = ($val | get -o numerator | default 0 | into float)
    let den = ($val | get -o denominator | default 1 | into float)
    if $den != 0 {
      ($num / $den * 100) | math round --precision 2
    } else { 0.0 }
  } else {
    (($val | into float) * 100) | math round --precision 2
  }
  $"($pct_val)%"
}
# ─── Main ────────────────────────────────────────────────────────────────────
# Query delegated stake for pools and DRep in a playground environment
def main [
    environment?: string  # Playground environment (e.g. "preview"); falls back to $ENV
] {
  let env_name = (resolve-env $environment)
  check-network $env_name
  let net = (net-args)
  print $"(ansi green_bold)Querying delegation for: ($env_name)(ansi reset)"
  print ""
  let tip = (check-node-synced $env_name $net)
  let current_epoch = ($tip.epoch)
  print $"  Epoch: ($current_epoch)  Slot: ($tip.slot)  Sync: ($tip.syncProgress)%"
  print ""
  # ── Our Pools ─────────────────────────────────────────────────────────────
  let groups = (find-groups $env_name)
  mut pool_rows: list<record> = []
  mut our_pool_mark_total: int = 0
  if ($groups | is-empty) {
    print $"(ansi yellow)  No pool groups found for ($env_name).(ansi reset)"
  } else {
    for group in $groups {
      let pool_files = (find-pool-id-files $group)
      for pf in $pool_files {
        let pool_name = ($pf | path basename | str replace '-pool.id' '')
        print -n $"  Querying ($pool_name)...\r"
        let pool_id = (sops-decrypt $pf | str trim)
        let stake = (try {
          query-pool-stake $pool_id $net
        } catch {
          {mark: 0, set: 0, go: 0}
        })
        $our_pool_mark_total = $our_pool_mark_total + $stake.mark
        $pool_rows = ($pool_rows | append {
                    Group:               $group
                    Pool:                $pool_name
                    "Pool ID":           $pool_id
                    "Mark (next epoch)": (lovelace-to-ada $stake.mark)
                    "Set (current)":     (lovelace-to-ada $stake.set)
                    "Go (previous)":     (lovelace-to-ada $stake.go)
                })
      }
    }
    print $"  Queried ($pool_rows | length) pool\(s\)                    "
    print ""
    print "  Pool Delegation — stake by snapshot:"
    print ($pool_rows | table)
  }
  # ── Our DRep ──────────────────────────────────────────────────────────────
  let drep_vkey = $"secrets/envs/($env_name)/drep/drep-0.vkey"
  mut our_drep_stake: int = 0
  if ($drep_vkey | path exists) {
    print -n "  Querying DRep...\r"
    let drep = (try {
      query-drep-info $drep_vkey $net
    } catch {
      {drep_id: "query failed", stake: 0, expiry: null}
    })
    $our_drep_stake = $drep.stake
    print "                          "
    let drep_row = [
      {
        "DRep ID": $drep.drep_id
        "Delegated Stake": (lovelace-to-ada $drep.stake)
        "Expiry Epoch": ($drep.expiry | default "n/a" | into string)
      }
    ]
    print "  DRep Delegation:"
    print ($drep_row | table)
  } else {
    print $"(ansi yellow)  No DRep found for ($env_name).(ansi reset)"
  }
  # ── Network-wide distributions ────────────────────────────────────────────
  print $"(ansi green_bold)Querying network-wide distributions...(ansi reset)"
  print ""
  print -n "  Querying DRep distribution...\r"
  let drep_totals = (try {
    query-drep-totals $current_epoch $net
  } catch {
    {
      stake_total: 0
      active_stake: 0
      expired_stake: 0
      always_abstain: 0
      always_noconf: 0
      active_count: 0
      expired_count: 0
    }
  })
  print -n "  Querying SPO distribution...\r"
  let pool_totals = (try {
    query-pool-totals $net
  } catch {
    {
      stake_total: 0
      abstain_total: 0
      noconf_total: 0
      pool_count: 0
    }
  })
  print "                                        "
  # ── DRep voting denominator ───────────────────────────────────────────────
  # Denominator = active DRep stake + alwaysNoConfidence (alwaysAbstain and expired are excluded)
  let drep_denominator = $drep_totals.active_stake + $drep_totals.always_noconf
  let drep_summary = [
    {
      Metric: "DRep Stake Total"
      Value: (lovelace-to-ada $drep_totals.stake_total)
      Detail: "all dreps + system"
    }
    {
      Metric: "DRep Active Stake"
      Value: (lovelace-to-ada $drep_totals.active_stake)
      Detail: $"($drep_totals.active_count) drep\(s\)"
    }
    {
      Metric: "DRep Expired Stake"
      Value: (lovelace-to-ada $drep_totals.expired_stake)
      Detail: $"($drep_totals.expired_count) drep\(s\) — excluded from voting"
    }
    {
      Metric: "Always Abstain"
      Value: (lovelace-to-ada $drep_totals.always_abstain)
      Detail: "excluded from denominator"
    }
    {
      Metric: "Always No Confidence"
      Value: (lovelace-to-ada $drep_totals.always_noconf)
      Detail: "in denominator; votes Yes on NoConfidence"
    }
    {
      Metric: "DRep Vote Denominator"
      Value: (lovelace-to-ada $drep_denominator)
      Detail: "active + noConfidence"
    }
    {
      Metric: "Our DRep Stake"
      Value: (lovelace-to-ada $our_drep_stake)
      Detail: (pct $our_drep_stake $drep_denominator)
    }
  ]
  print "  DRep Governance Summary:"
  print ($drep_summary | table)
  # ── Pool voting denominator ───────────────────────────────────────────────
  # For most actions: total - abstain (pools that don't vote count against, like DReps)
  # For HardForkInitiation: total - abstain (same)
  # For NoConfidence: noconf moves to yes numerator, abstain excluded
  let pool_denominator = $pool_totals.stake_total - $pool_totals.abstain_total
  let pool_summary = [
    {
      Metric: "Pool Stake Total"
      Value: (lovelace-to-ada $pool_totals.stake_total)
      Detail: $"($pool_totals.pool_count) pool\(s\)"
    }
    {
      Metric: "Pool Abstain Total"
      Value: (lovelace-to-ada $pool_totals.abstain_total)
      Detail: "SPOs delegated to alwaysAbstain"
    }
    {
      Metric: "Pool No Confidence Total"
      Value: (lovelace-to-ada $pool_totals.noconf_total)
      Detail: "SPOs delegated to alwaysNoConfidence"
    }
    {
      Metric: "Pool Vote Denominator"
      Value: (lovelace-to-ada $pool_denominator)
      Detail: "total - abstain (varies by action type)"
    }
    {
      Metric: "Our Pools Stake (mark)"
      Value: (lovelace-to-ada $our_pool_mark_total)
      Detail: (pct $our_pool_mark_total $pool_denominator)
    }
  ]
  print "  Pool Governance Summary:"
  print ($pool_summary | table)
  # ── Voting thresholds from protocol parameters ────────────────────────────
  debug-cmd "cardano-cli" (["latest", "query", "protocol-parameters"] | append $net)
  let pparams = (^cardano-cli latest query protocol-parameters ...$net | from json)
  let dvt = ($pparams | get dRepVotingThresholds)
  let pvt = ($pparams | get poolVotingThresholds)
  # Committee threshold from gov-state
  debug-cmd "cardano-cli" (["latest", "query", "gov-state"] | append $net)
  let gov_state = (^cardano-cli latest query gov-state ...$net | from json)
  let cc_threshold_raw = (
    $gov_state | get -o committee | get -o threshold | default 0
  )
  let cc_threshold = (threshold-pct $cc_threshold_raw)
  # Participants per action type from CIP-1694:
  #   CC = Constitutional Committee, DRep = Delegated Representatives, SPO = Stake Pool Operators
  #   "—" means that voter group does not participate for that action type
  #   ParameterChange DRep threshold = max across all applicable parameter groups
  #   ParameterChange SPO threshold applies only when security group params are included
  let thresholds = [
    {
      "Action Type": "No Confidence"
      "DRep (%)": (threshold-pct ($dvt | get committeeNoConfidence))
      "Pool (%)": (threshold-pct ($pvt | get committeeNoConfidence))
      "CC (%)": "—"
    }
    {
      "Action Type": "Update Committee"
      "DRep (%)": (threshold-pct ($dvt | get committeeNormal))
      "Pool (%)": (threshold-pct ($pvt | get committeeNormal))
      "CC (%)": "—"
    }
    {
      "Action Type": "New Constitution"
      "DRep (%)": (threshold-pct ($dvt | get updateToConstitution))
      "Pool (%)": "—"
      "CC (%)": $cc_threshold
    }
    {
      "Action Type": "Hard Fork"
      "DRep (%)": (threshold-pct ($dvt | get hardForkInitiation))
      "Pool (%)": (threshold-pct ($pvt | get hardForkInitiation))
      "CC (%)": $cc_threshold
    }
    {
      "Action Type": "PP Network Group"
      "DRep (%)": (threshold-pct ($dvt | get ppNetworkGroup))
      "Pool (%)": "—"
      "CC (%)": $cc_threshold
    }
    {
      "Action Type": "PP Economic Group"
      "DRep (%)": (threshold-pct ($dvt | get ppEconomicGroup))
      "Pool (%)": "—"
      "CC (%)": $cc_threshold
    }
    {
      "Action Type": "PP Technical Group"
      "DRep (%)": (threshold-pct ($dvt | get ppTechnicalGroup))
      "Pool (%)": "—"
      "CC (%)": $cc_threshold
    }
    {
      "Action Type": "PP Governance Group"
      "DRep (%)": (threshold-pct ($dvt | get ppGovGroup))
      "Pool (%)": "—"
      "CC (%)": $cc_threshold
    }
    {
      "Action Type": "PP Security Group"
      "DRep (%)": "max of applicable groups"
      "Pool (%)": (threshold-pct ($pvt | get ppSecurityGroup))
      "CC (%)": $cc_threshold
    }
    {
      "Action Type": "Treasury Withdrawal"
      "DRep (%)": (threshold-pct ($dvt | get treasuryWithdrawal))
      "Pool (%)": "—"
      "CC (%)": $cc_threshold
    }
    {
      "Action Type": "Info Action"
      "DRep (%)": "n/a"
      "Pool (%)": "n/a"
      "CC (%)": "n/a"
    }
  ]
  print $"(ansi green_bold)Voting Thresholds \(from protocol parameters\):(ansi reset)"
  print ""
  print ($thresholds | table)
}
