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
#   query-delegation.nu leios --group-regex '^leios(red)?[0-9]+$'
# --group-regex overrides pool group discovery only; DRep and network totals
# still use the selected environment. All matching groups must belong to it.
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
def find-groups [pattern: string] {
  let groups_dir = "secrets/groups"
  if not ($groups_dir | path exists) { return [] }
  ls $groups_dir | where type == dir | each { |d| $d.name | path basename } | where { |name| $name =~ $pattern } | sort
}
# Find pool.id files in a group's no-deploy directory
def find-pool-id-files [group: string] {
  let nd = $"secrets/groups/($group)/no-deploy"
  if not ($nd | path exists) { return [] }
  glob $"($nd)/*-pool.id" | sort
}
# ─── Query functions ─────────────────────────────────────────────────────────
def query-pool-stake [pool_id: string, net_args: list<string>, --era: string] {
  debug-cmd "cardano-cli" ([$era, "query", "stake-snapshot", "--stake-pool-id", $pool_id] | append $net_args)
  let data = (^cardano-cli $era query stake-snapshot --stake-pool-id $pool_id ...$net_args | from json)
  # A pool absent from all three snapshots has no entry in pools.
  let pools = $data | get pools
  if ($pools | is-empty) {
    print --stderr $"Warning: pool ($pool_id) is absent from the stake snapshots; reporting zero mark/set/go stake."
    return {
      mark: 0
      set: 0
      go: 0
      total_set: ($data | get total.stakeSet)
    }
  }
  # Pool stake is nested under pools.<hex-key-hash>; extract the first (only) entry
  let pool_data = (
    $pools | transpose _hash info | first | get info
  )
  {
    total_set: ($data | get total.stakeSet)
    mark: ($pool_data | get -o stakeMark | default 0)
    set: ($pool_data | get -o stakeSet | default 0)
    go: ($pool_data | get -o stakeGo | default 0)
  }
}
def query-drep-info [vkey_path: string, net_args: list<string>, --era: string] {
  let f_vkey = (^mktemp --suffix .vkey | str trim)
  try {
    sops-decrypt $vkey_path | save --force $f_vkey
    debug-cmd "cardano-cli" [
      $era
      "governance"
      "drep"
      "id"
      "--drep-verification-key-file"
      $f_vkey
    ]
    let drep_id = (^cardano-cli $era governance drep id --drep-verification-key-file $f_vkey | str trim)
    debug-cmd "cardano-cli" ([
      $era
      "query"
      "drep-state"
      "--drep-verification-key-file"
      $f_vkey
      "--include-stake"
    ] | append $net_args)
    let state = (^cardano-cli $era query drep-state --drep-verification-key-file $f_vkey --include-stake ...$net_args | from json)
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
def query-drep-totals [epoch: int, net_args: list<string>, --era: string] {
  # drep-stake-distribution includes expired dreps and system dreps (alwaysAbstain, alwaysNoConfidence)
  debug-cmd "cardano-cli" ([$era, "query", "drep-stake-distribution", "--all-dreps"] | append $net_args)
  let drep_dist = (^cardano-cli $era query drep-stake-distribution --all-dreps ...$net_args | from json)
  let dist_entries = ($drep_dist | transpose key value)
  let always_abstain = (
    $dist_entries | where key == "drep-alwaysAbstain" | get -o value | safe-sum
  )
  let always_noconf = (
    $dist_entries | where key == "drep-alwaysNoConfidence" | get -o value | safe-sum
  )
  let stake_total = ($dist_entries | get value | safe-sum)
  # drep-state with --include-stake gives per-drep expiry and stake (excludes system dreps)
  debug-cmd "cardano-cli" ([$era, "query", "drep-state", "--all-dreps", "--include-stake"] | append $net_args)
  let drep_state = (^cardano-cli $era query drep-state --all-dreps --include-stake ...$net_args | from json)
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
def query-pool-totals [net_args: list<string>, --era: string, --our-pools: list<string>] {
  debug-cmd "cardano-cli" ([$era, "query", "spo-stake-distribution", "--all-spos"] | append $net_args)
  let pool_dist = (^cardano-cli $era query spo-stake-distribution --all-spos ...$net_args | from json)
  let stake_total = ($pool_dist | each { |e| $e | get 1 } | safe-sum)
  let abstain_total = (
    $pool_dist | where { |e| ($e | get -o 2) == "drep-alwaysAbstain" } | each { |e| $e | get 1 } | safe-sum
  )
  let noconf_total = (
    $pool_dist | where { |e| ($e | get -o 2) == "drep-alwaysNoConfidence" } | each { |e| $e | get 1 } | safe-sum
  )
  let our_stake = (
    $pool_dist | where {|e| ($e | get 0) in $our_pools } | each {|e| $e | get 1 } | safe-sum
  )
  let pool_count = ($pool_dist | length)
  {
    stake_total: $stake_total
    abstain_total: $abstain_total
    noconf_total: $noconf_total
    pool_count: $pool_count
    our_stake: $our_stake
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
# Conservative planning scenario: our eligible stake votes Yes; all other
# stake in the supplied denominator counts against. Round funding UP to ADA.
def vote-projection [threshold, stake: record]: nothing -> record {
  let t = if ($threshold | describe | str starts-with 'record') {
    $threshold.numerator / $threshold.denominator
  } else {
    $threshold | into float
  }
  if $t < 0 or $t > 1 { error make {msg: "Voting threshold must be between 0 and 1"} }
  let gap = ([
    0
    ($t * $stake.total - $stake.yes)
  ] | math max)
  let existing = ($gap / 1_000_000 | math ceil | into int)
  let fresh = if $gap == 0 { "0 ADA" } else if $t == 1 {
    "unreachable by adding stake"
  } else {
    $"(comma-sep ($gap / (1 - $t) / 1_000_000 | math ceil | into int)) ADA"
  }
  {
    Threshold: (threshold-pct $threshold)
    "Our Yes ADA": (comma-sep ($stake.yes // 1_000_000))
    "Required Yes ADA": (comma-sep ($t * $stake.total / 1_000_000 | math ceil | into int))
    "Existing → Yes ADA": (comma-sep $existing)
    "New stake needed": $fresh
  }
}
# ─── Main ────────────────────────────────────────────────────────────────────
# Query delegated stake for pools and DRep in a playground environment
def main [
    environment?: string  # Playground environment (e.g. "preview"); falls back to $ENV
    --group-regex: string # Pool group directory regex; default: ^<environment>\d+$
] {
  let env_name = (resolve-env $environment)
  let group_pattern = $group_regex | default $"^($env_name)\\d+$"
  # Validate the regex before querying the node or decrypting pool IDs.
  "" =~ $group_pattern | ignore
  check-network $env_name
  let net = (net-args)
  print $"(ansi green_bold)Querying delegation for: ($env_name)(ansi reset)"
  print ""
  let tip = (check-node-synced $env_name $net)
  # The CLI latest alias can still be Conway on a Dijkstra-capable build.
  let era = $tip.era | str downcase
  let current_epoch = ($tip.epoch)
  print $"  Era: ($era)  Epoch: ($current_epoch)  Slot: ($tip.slot)  Sync: ($tip.syncProgress)%"
  print ""
  # ── Our Pools ─────────────────────────────────────────────────────────────
  let groups = (find-groups $group_pattern)
  print $"  Pool group regex: ($group_pattern)"
  mut pool_rows: list<record> = []
  mut our_pool_set_total: int = 0
  mut our_pool_hashes: list<string> = []
  mut network_set_total: int = 0
  if ($groups | is-empty) {
    print $"(ansi yellow)  No pool groups matched ($group_pattern).(ansi reset)"
  } else {
    for group in $groups {
      let pool_files = (find-pool-id-files $group)
      for pf in $pool_files {
        let pool_name = ($pf | path basename | str replace '-pool.id' '')
        print -n $"  Querying ($pool_name)...\r"
        let pool_id = (sops-decrypt $pf | str trim)
        let stake = query-pool-stake $pool_id $net --era $era
        # CLI governance distributions use hex pool hashes, not bech32 IDs.
        let pool_hash = if ($pool_id | str starts-with 'pool1') {
          $pool_id | ^bech32 | str trim
        } else { $pool_id }
        if $pool_hash not-in $our_pool_hashes {
          $our_pool_set_total = $our_pool_set_total + $stake.set
          $our_pool_hashes = $our_pool_hashes | append $pool_hash
        }
        $network_set_total = $stake.total_set
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
  mut our_expired_drep_stake: int = 0
  mut our_drep_expired = false
  if ($drep_vkey | path exists) {
    print -n "  Querying DRep...\r"
    let drep = query-drep-info $drep_vkey $net --era $era
    $our_drep_expired = $drep.expiry != null and $drep.expiry < $current_epoch
    if $our_drep_expired {
      $our_expired_drep_stake = $drep.stake
    }
    $our_drep_stake = if $drep.expiry != null and $drep.expiry >= $current_epoch {
      $drep.stake
    } else { 0 }
    print "                          "
    let drep_row = [
      {
        "DRep ID": $drep.drep_id
        "Delegated Stake": (lovelace-to-ada $drep.stake)
        "Expiry Epoch": ($drep.expiry | default "n/a" | into string)
        Status: (if $drep.expiry == null { "unregistered" } else if $drep.expiry >= $current_epoch { "active" } else { "expired" })
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
  let drep_totals = query-drep-totals $current_epoch $net --era $era
  print -n "  Querying SPO distribution...\r"
  let pool_totals = query-pool-totals $net --era $era --our-pools $our_pool_hashes
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
      Metric: "Our Active DRep Stake"
      Value: (lovelace-to-ada $our_drep_stake)
      Detail: (pct $our_drep_stake $drep_denominator)
    }
  ]
  print "  DRep Governance Summary:"
  print ($drep_summary | table)
  # Use the same set snapshot for both sides of the forging percentage.
  print "  Pool Forging Summary (current set snapshot):"
  print ([
    {
      Metric: "Network Set Stake"
      Value: (lovelace-to-ada $network_set_total)
      Detail: "includes abstaining pools"
    }
    {
      Metric: "Our Set Stake"
      Value: (lovelace-to-ada $our_pool_set_total)
      Detail: (pct $our_pool_set_total $network_set_total)
    }
  ] | table)
  # Governance distribution share is not an action-specific approval ratio.
  # Explicit votes, default votes and action type determine that denominator.
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
      Metric: "Pool Governance Denominator"
      Value: (lovelace-to-ada $pool_totals.stake_total)
      Detail: "full governance distribution; not an approval ratio"
    }
    {
      Metric: "Our Governance Stake"
      Value: (lovelace-to-ada $pool_totals.our_stake)
      Detail: (pct $pool_totals.our_stake $pool_totals.stake_total)
    }
  ]
  print "  Pool Governance Summary:"
  print ($pool_summary | table)
  # ── Voting thresholds from protocol parameters ────────────────────────────
  debug-cmd "cardano-cli" ([$era, "query", "protocol-parameters"] | append $net)
  let pparams = (^cardano-cli $era query protocol-parameters ...$net | from json)
  let dvt = ($pparams | get dRepVotingThresholds)
  let pvt = ($pparams | get poolVotingThresholds)
  # Committee threshold from gov-state
  debug-cmd "cardano-cli" ([$era, "query", "gov-state"] | append $net)
  let gov_state = (^cardano-cli $era query gov-state ...$net | from json)
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
  print ""
  print "Conservative voting-stake projections (not a tally of submitted votes):"
  print "Assumes our eligible stake votes Yes and all other counted stake votes No."
  print "SPO baseline includes all governance stake; DRep baseline excludes expired/always-abstain stake."
  print "No credit is taken for other Yes votes or automatic NoConfidence support."
  print "Existing → Yes moves stake already in the denominator; new stake increases both Yes and total."
  print "Amounts are rounded up to whole ADA. Added stake must become effective in the voting distribution."
  print "An expired DRep must be renewed before funding it can contribute to Yes."
  print "Committee approval and other enactment conditions still apply."
  let projection_specs = [
    {
      action: "No Confidence"
      drep: $dvt.committeeNoConfidence
      spo: $pvt.committeeNoConfidence
    }
    {
      action: "Committee (normal)"
      drep: $dvt.committeeNormal
      spo: $pvt.committeeNormal
    }
    {
      action: "Committee (no confidence)"
      drep: $dvt.committeeNoConfidence
      spo: $pvt.committeeNoConfidence
    }
    {
      action: "New Constitution"
      drep: $dvt.updateToConstitution
      spo: null
    }
    {
      action: "Hard Fork"
      drep: $dvt.hardForkInitiation
      spo: $pvt.hardForkInitiation
    }
    {
      action: "PP Network"
      drep: $dvt.ppNetworkGroup
      spo: null
    }
    {
      action: "PP Economic"
      drep: $dvt.ppEconomicGroup
      spo: null
    }
    {
      action: "PP Technical"
      drep: $dvt.ppTechnicalGroup
      spo: null
    }
    {
      action: "PP Governance"
      drep: $dvt.ppGovGroup
      spo: null
    }
    {
      action: "PP Security"
      drep: null
      spo: $pvt.ppSecurityGroup
    }
    {
      action: "Treasury Withdrawal"
      drep: $dvt.treasuryWithdrawal
      spo: null
    }
  ]
  let projection_voters = if $our_drep_expired {
    [DRep, "DRep if renewed", SPO]
  } else { [DRep, SPO] }
  for voter in $projection_voters {
    let is_drep = $voter != "SPO"
    let stake = if $voter == "DRep if renewed" {
      {
        yes: $our_expired_drep_stake
        total: ($drep_denominator + $our_expired_drep_stake)
      }
    } else if $is_drep {
      {
        yes: $our_drep_stake
        total: $drep_denominator
      }
    } else {
      {
        yes: $pool_totals.our_stake
        total: $pool_totals.stake_total
      }
    }
    let field = if $is_drep { "drep" } else { "spo" }
    print ""
    print $"  ($voter) stake projection:"
    if $voter == "DRep if renewed" {
      print $"  Assumes renewal restores (lovelace-to-ada $our_expired_drep_stake) to both Yes and total, with other stake unchanged."
      print "  New stake needed below is additional funding AFTER renewal; existing delegated stake is already included."
    }
    print (
      $projection_specs | where {|row| ($row | get $field) != null } | each {|row|
      {Action: $row.action} | merge (vote-projection ($row | get $field) $stake)
    } | table
    )
    print "  New-stake equations (x, Yes and total are in ADA):"
    print "  t = (x + Yes) / (x + total); x = max(0, (t * total - Yes) / (1 - t)), rounded up to whole ADA."
    print "  At t = 1, adding stake cannot close an existing No-stake gap."
    for row in ($projection_specs | where {|row| ($row | get $field) != null }) {
      let threshold = $row | get $field
      let t = if ($threshold | describe | str starts-with 'record') {
        $threshold.numerator / $threshold.denominator
      } else {
        $threshold | into float
      }
      let yes_ada = lovelace-to-ada $stake.yes | str replace ' ADA' ''
      let total_ada = lovelace-to-ada $stake.total | str replace ' ADA' ''
      let result = vote-projection $threshold $stake
      print $"  ($row.action): ($t) = \(x + ($yes_ada)\) / \(x + ($total_ada)\) → ($result.'New stake needed')"
    }
  }
  print ""
  print "Parameter updates spanning groups require the highest applicable DRep threshold; security updates also require SPO approval."
}
