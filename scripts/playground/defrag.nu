#!/usr/bin/env nu
# Cardano UTxO Defragmentation Tool
#
# Defragments a payment key address in two passes:
#   Pass 1 — consolidates all lovelace-only UTxOs into a single UTxO.
#   Pass 2 — consolidates all native-token-bearing UTxOs into a single UTxO.
# Either pass is skipped when fewer than 2 UTxOs exist in that category.
#
# The signing key file (.skey) is expected to be sops-encrypted at rest and is
# decrypted on the fly.  Private key material is written only to short-lived
# mktemp files that are deleted immediately after use.
#
# By default nothing is submitted: each pass is built and signed, and the signed
# tx is left in the directory the script was called from for manual inspection
# and submission.  Those files are submittable as-is.
#
# --submit restores the submit-and-wait behaviour, still behind a y/N prompt.
# --dry-run reports what would be consolidated and builds nothing.
#
# An active leios-pin.sh or node-local-pin.sh is honoured even when PATH has
# lost its prepend, and the cardano-cli in use is printed before any work.
#
# ENVIRONMENT VARIABLES (provided by the playground devShell):
#   TESTNET_MAGIC            Cardano testnet magic number
#   CARDANO_NODE_SOCKET_PATH Path to the running cardano-node socket
#
# USAGE (run from repo root inside the devShell):
#   defrag.nu <environment> <key-path> [--dry-run] [--submit]
#
# --dry-run takes precedence when both flags are given.
#
# ARGUMENTS:
#   environment  Playground environment: preview, preprod, etc.
#                Validated against TESTNET_MAGIC / CARDANO_NODE_NETWORK_ID.
#   key-path     Path and filename without the .skey extension,
#                e.g. secrets/envs/preview/utxo-keys/rich-utxo
#                The file <key-path>.skey must exist and be sops-encrypted.
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
  ^sops --config $config --input-type binary --output-type binary --decrypt $file
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
# ─── Network helpers ──────────────────────────────────────────────────────────
# Expected TESTNET_MAGIC for known environments
def expected-magic [environment: string] { match $environment {
  "preview" => "2"
  "preprod" => "1"
  _ => null
} }
# Sanity-check that TESTNET_MAGIC and CARDANO_NODE_NETWORK_ID match the environment
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
# ─── Tooling resolution ───────────────────────────────────────────────────────
# leios-pin.sh and node-local-pin.sh prepend a symlink dir to PATH, but a
# `nix develop -c` or a direnv reload rebuilds PATH from the devShell and drops
# that prepend while the pin's marker variable survives. Without this the
# devShell cardano-cli gets used against a chain that needs the pinned one.
def --env respect-pins []: nothing -> list<string> {
  let pins = [
    {
      marker: "LEIOS_PATH_BACKUP"
      dir: ($nu.home-dir | path join ".local" "bin")
    }
    {
      marker: "NODE_LOCAL_PATH_BACKUP"
      dir: ($nu.home-dir | path join ".local" "bin-node-local")
    }
  ] | where {|p| ($p.marker in $env) and (($p.dir | path join "cardano-cli") | path exists)}
  # Move to the front rather than only adding when absent. `nix develop` can
  # keep the dir on PATH but reorder it behind the devShell's own bin, which
  # still resolves the wrong cardano-cli.
  for p in $pins { $env.PATH = ($env.PATH | where {|d| $d != $p.dir} | prepend $p.dir) }
  $pins | get dir
}
# The node's era as a cardano-cli command group. `latest` is an alias for the
# newest *stable* era, so it silently builds a Conway tx against a Dijkstra node
# and the node rejects it. Probe with `complete`; a plain `try` around
# `o+e>| ignore` swallows the non-zero exit and reports success.
def era-group [tip_era: string]: nothing -> string {
  let era = $tip_era | str downcase
  if (^cardano-cli $era --help | complete | get exit_code) != 0 {
    error make --unspanned {
      msg: $"cardano-cli has no '($era)' era command group, but the node is in the ($tip_era) era. Pin a cardano-cli that knows it, e.g. with scripts/playground/leios-pin.sh or node-local-pin.sh."
    }
  }
  $era
}
# Fail early and visibly rather than deep inside a transaction build.
def report-tooling [] {
  let cli = which cardano-cli | get --optional path.0
  if ($cli | is-empty) {
    error make --unspanned {msg: "cardano-cli not found on PATH. Are you inside the playground devShell?"}
  }
  print $"  cardano-cli: ($cli)"
  print $"  version:     (^cardano-cli --version | lines | first | str trim)"
}
# ─── Transaction helpers ─────────────────────────────────────────────────────
def wait-for-tx [txid: string, net_args: list<string>, --era: string] {
  print $"  Waiting for tx ($txid) to leave mempool..."
  loop {
    let result = (^cardano-cli $era query tx-mempool tx-exists $txid ...$net_args | from json)
    if not ($result | get exists) {
      print "  Transaction confirmed on-chain."
      break
    }
    sleep 5sec
  }
}
def confirm-and-submit [tx_file: string, net_args: list<string>, --era: string] {
  print "\n  Transaction view:"
  print (^cardano-cli debug transaction view --tx-file $tx_file --output-json)
  print ""
  let response = (input "  Submit this transaction? [y/N] ")
  if ($response | str downcase | str trim) != "y" {
    print $"(ansi yellow)Transaction cancelled.(ansi reset)"
    return null
  }
  ^cardano-cli $era transaction submit --tx-file $tx_file ...$net_args
  ^cardano-cli $era transaction txid --tx-file $tx_file --output-text | str trim
}
# Consolidate every utxo in the list into a single change output.
def build-args [utxos: list<record>, out_file: string, --address: string]: nothing -> list<string> {
  $utxos | each { |u| ["--tx-in" $u.txin] } | flatten | append [
    "--change-address"
    $address
    "--witness-override"
    "1"
    "--out-file"
    $out_file
  ]
}
# The tx body is a short-lived temp file; the signed tx lands in out_file.
def build-and-sign [
  utxos: list<record>
  out_file: string
  --address: string
  --skey-file: string
  --net-args: list<string>
  --era: string
] {
  let f_tx_body = ^mktemp --suffix .txbody | str trim
  ^cardano-cli $era transaction build ...(build-args $utxos $f_tx_body --address $address | append $net_args)
  ^cardano-cli $era transaction sign --tx-body-file $f_tx_body --signing-key-file $skey_file --out-file $out_file
  rm --force $f_tx_body
}
def report-unsubmitted [tx_file: string, net_args: list<string>, --era: string] {
  print $"  Signed tx written to: ($tx_file)"
  print $"    inspect: cardano-cli debug transaction view --tx-file ($tx_file)"
  print $"    submit:  cardano-cli ($era) transaction submit --tx-file ($tx_file) ($net_args | str join ' ')"
}
# ─── Main ─────────────────────────────────────────────────────────────────────
# Defragment a payment address: consolidate lovelace-only and native token UTxOs
def main [
    environment: string # Playground environment: preview, preprod, etc.
    key_path: string    # Path and filename without .skey extension (sops-encrypted)
    --dry-run           # Report what would be consolidated, build nothing
    --submit            # Submit after confirmation; default builds and signs only
] {
  let stamp = date now | format date "%Y%m%d-%H%M%S"
  print "Resolving cardano tooling..."
  let pinned = respect-pins
  if not ($pinned | is-empty) {
    print $"  pin active:  ($pinned | str join ', ')"
  }
  report-tooling
  check-network $environment
  let skey_file = $"($key_path).skey"
  if not ($skey_file | path exists) {
    error make --unspanned {
      msg: $"Signing key not found: ($skey_file)"
    }
  }
  let net = (net-args)
  # Verify node is reachable and fully synced before doing any work
  print $"Checking node connectivity and sync status on environment ($environment)..."
  let tip_json = try {
    ^cardano-cli query tip ...$net | from json
  } catch {
    error make --unspanned {msg: "Cannot connect to cardano-node. Is the node running and CARDANO_NODE_SOCKET_PATH set correctly?"}
  }
  print ($tip_json | to json --indent 2)
  # Match the node's era rather than assuming `latest`
  let era = era-group ($tip_json | get era)
  print $"  era group:   ($era)"
  let sync_pct = ($tip_json | get syncProgress | into float)
  if $sync_pct < 100.0 {
    error make --unspanned {
      msg: $"Node is only ($sync_pct)% synced. Wait for it to reach 100% before defragmenting."
    }
  }
  # Decrypt the signing key and derive the payment address
  print $"\nDecrypting signing key for ($environment)..."
  let skey_content = (sops-decrypt $skey_file)
  let f_skey = (^mktemp --suffix .skey | str trim)
  let f_vkey_raw = (^mktemp --suffix .vkey | str trim)
  let f_vkey = (^mktemp --suffix .vkey | str trim)
  let f_addr = (^mktemp --suffix .addr | str trim)
  $skey_content | save --force $f_skey
  ^cardano-cli latest key verification-key --signing-key-file $f_skey --verification-key-file $f_vkey_raw
  # Convert to non-extended verification key if needed for address building
  let vkey_json = (open --raw $f_vkey_raw | from json)
  if ($vkey_json.type | str contains "Extended") {
    ^cardano-cli latest key non-extended-key --extended-verification-key-file $f_vkey_raw --verification-key-file $f_vkey
  } else {
    cp $f_vkey_raw $f_vkey
  }
  ^cardano-cli latest address build --payment-verification-key-file $f_vkey ...$net --out-file $f_addr
  let address = (open --raw $f_addr | str trim)
  rm --force $f_vkey_raw $f_vkey $f_addr
  print $"  Address: ($address)"
  # Query UTxOs
  print $"\nQuerying UTxOs..."
  let all_data = (^cardano-cli $era query utxo --address $address --output-json ...$net | from json)
  let all_utxos = if ($all_data | is-empty) { [] } else {
    $all_data | transpose key value
  }
  # Lovelace-only UTxOs
  let lovelace_utxos = ($all_utxos | where { |row| ($row.value.value | columns | length) == 1 } | each { |row| { txin: $row.key, lovelace: $row.value.value.lovelace } })
  let lovelace_count = ($lovelace_utxos | length)
  let total_lovelace = if ($lovelace_utxos | is-empty) { 0 } else {
    $lovelace_utxos | each { |u| $u.lovelace } | math sum
  }
  # Native-token-bearing UTxOs
  let token_utxos = ($all_utxos | where { |row| ($row.value.value | columns | length) > 1 } | each { |row| { txin: $row.key, lovelace: $row.value.value.lovelace } })
  let token_count = ($token_utxos | length)
  let total_token_lovelace = if ($token_utxos | is-empty) { 0 } else {
    $token_utxos | each { |u| $u.lovelace } | math sum
  }
  print $"  Lovelace-only UTxOs: ($lovelace_count)  \((lovelace-to-ada $total_lovelace)\)"
  print $"  Native token UTxOs:  ($token_count)  \((lovelace-to-ada $total_token_lovelace)\)"
  if $lovelace_count >= 2 {
    print "\n  Lovelace-only UTxOs to consolidate:"
    for utxo in $lovelace_utxos {
      print $"    ($utxo.txin)  (lovelace-to-ada $utxo.lovelace)"
    }
  }
  if $token_count >= 2 {
    print "\n  Native token UTxOs to consolidate:"
    for utxo in $token_utxos {
      print $"    ($utxo.txin)  (lovelace-to-ada $utxo.lovelace)"
    }
  }
  if $lovelace_count < 2 and $token_count < 2 {
    print $"\n(ansi yellow)Nothing to defrag — need at least 2 UTxOs in either category.(ansi reset)"
    rm --force $f_skey
    return
  }
  if $dry_run {
    if $lovelace_count >= 2 {
      print $"\n  Would consolidate ($lovelace_count) lovelace-only UTxOs into 1."
    }
    if $token_count >= 2 {
      print $"  Would consolidate ($token_count) native token UTxOs into 1."
    }
    print $"\n(ansi yellow)Dry run — no transaction submitted.(ansi reset)"
    rm --force $f_skey
    return
  }
  # ── Pass 1: consolidate lovelace-only UTxOs ──────────────────────────────
  if $lovelace_count >= 2 {
    print $"\n  Pass 1: consolidating ($lovelace_count) lovelace-only UTxOs into 1..."
    let f_tx_signed = if $submit {
      ^mktemp --suffix .tx | str trim
    } else {
      $env.PWD | path join $"defrag-($environment)-lovelace-($stamp).tx"
    }
    try {
      build-and-sign $lovelace_utxos $f_tx_signed --address $address --skey-file $f_skey --net-args $net --era $era
    } catch {|e|
      rm --force $f_skey
      error make --unspanned {
        msg: $"Pass 1 build failed: ($e.msg)"
      }
    }
    if not $submit {
      report-unsubmitted $f_tx_signed $net --era $era
    } else {
      let txid = (confirm-and-submit $f_tx_signed $net --era $era)
      rm --force $f_tx_signed
      if $txid == null {
        rm --force $f_skey
        return
      }
      wait-for-tx $txid $net --era $era
      print $"(ansi green)Pass 1 complete! TxID: ($txid)(ansi reset)"
      print $"  Consolidated ($lovelace_count) lovelace-only UTxOs into 1."
    }
  }
  # ── Pass 2: consolidate native token UTxOs ───────────────────────────────
  if $token_count >= 2 {
    print $"\n  Pass 2: consolidating ($token_count) native token UTxOs into 1..."
    let f_tx_signed = if $submit {
      ^mktemp --suffix .tx | str trim
    } else {
      $env.PWD | path join $"defrag-($environment)-token-($stamp).tx"
    }
    try {
      build-and-sign $token_utxos $f_tx_signed --address $address --skey-file $f_skey --net-args $net --era $era
    } catch {|e|
      rm --force $f_skey
      error make --unspanned {
        msg: $"Pass 2 build failed: ($e.msg)"
      }
    }
    if not $submit {
      report-unsubmitted $f_tx_signed $net --era $era
    } else {
      let txid = (confirm-and-submit $f_tx_signed $net --era $era)
      rm --force $f_tx_signed
      if $txid == null {
        rm --force $f_skey
        return
      }
      wait-for-tx $txid $net --era $era
      print $"(ansi green)Pass 2 complete! TxID: ($txid)(ansi reset)"
      print $"  Consolidated ($token_count) native token UTxOs into 1."
    }
  }
  # Clean up
  rm --force $f_skey
  if $submit {
    print $"\n(ansi green)Defrag complete at ($address)(ansi reset)"
  } else {
    print $"\n(ansi yellow)Nothing submitted. Inspect the signed tx files above, then submit with --submit or by hand.(ansi reset)"
  }
}
