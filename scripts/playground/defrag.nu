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
# ENVIRONMENT VARIABLES (provided by the playground devShell):
#   TESTNET_MAGIC            Cardano testnet magic number
#   CARDANO_NODE_SOCKET_PATH Path to the running cardano-node socket
#
# USAGE (run from repo root inside the devShell):
#   defrag.nu <environment> <key-path> [--dry-run]
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
# ─── Transaction helpers ─────────────────────────────────────────────────────
def wait-for-tx [txid: string, net_args: list<string>] {
  print $"  Waiting for tx ($txid) to leave mempool..."
  loop {
    let result = (^cardano-cli latest query tx-mempool tx-exists $txid ...$net_args | from json)
    if not ($result | get exists) {
      print "  Transaction confirmed on-chain."
      break
    }
    sleep 5sec
  }
}
def confirm-and-submit [tx_file: string, net_args: list<string>] {
  print "\n  Transaction view:"
  print (^cardano-cli debug transaction view --tx-file $tx_file --output-json)
  print ""
  let response = (input "  Submit this transaction? [y/N] ")
  if ($response | str downcase | str trim) != "y" {
    print $"(ansi yellow)Transaction cancelled.(ansi reset)"
    return null
  }
  ^cardano-cli latest transaction submit --tx-file $tx_file ...$net_args
  ^cardano-cli latest transaction txid --tx-file $tx_file --output-text | str trim
}
# ─── Main ─────────────────────────────────────────────────────────────────────
# Defragment a payment address: consolidate lovelace-only and native token UTxOs
def main [
    environment: string # Playground environment: preview, preprod, etc.
    key_path: string    # Path and filename without .skey extension (sops-encrypted)
    --dry-run           # Show details without submitting
] {
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
    ^cardano-cli latest query tip ...$net | from json
  } catch {
    error make --unspanned {msg: "Cannot connect to cardano-node. Is the node running and CARDANO_NODE_SOCKET_PATH set correctly?"}
  }
  print ($tip_json | to json --indent 2)
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
  let all_data = (^cardano-cli latest query utxo --address $address --output-json ...$net | from json)
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
    let f_tx_body = (^mktemp --suffix .txbody | str trim)
    let f_tx_signed = (^mktemp --suffix .tx | str trim)
    mut build_args: list<string> = []
    for utxo in $lovelace_utxos {
      $build_args = ($build_args | append [
        "--tx-in"
        $utxo.txin
      ])
    }
    $build_args = ($build_args | append [
      "--change-address"
      $address
      "--witness-override"
      "1"
      "--out-file"
      $f_tx_body
    ])
    ^cardano-cli latest transaction build ...($build_args | append $net)
    ^cardano-cli latest transaction sign --tx-body-file $f_tx_body --signing-key-file $f_skey --out-file $f_tx_signed
    let txid = (confirm-and-submit $f_tx_signed $net)
    rm --force $f_tx_body $f_tx_signed
    if $txid == null {
      rm --force $f_skey
      return
    }
    wait-for-tx $txid $net
    print $"(ansi green)Pass 1 complete! TxID: ($txid)(ansi reset)"
    print $"  Consolidated ($lovelace_count) lovelace-only UTxOs into 1."
  }
  # ── Pass 2: consolidate native token UTxOs ───────────────────────────────
  if $token_count >= 2 {
    print $"\n  Pass 2: consolidating ($token_count) native token UTxOs into 1..."
    let f_tx_body = (^mktemp --suffix .txbody | str trim)
    let f_tx_signed = (^mktemp --suffix .tx | str trim)
    mut build_args: list<string> = []
    for utxo in $token_utxos {
      $build_args = ($build_args | append [
        "--tx-in"
        $utxo.txin
      ])
    }
    $build_args = ($build_args | append [
      "--change-address"
      $address
      "--witness-override"
      "1"
      "--out-file"
      $f_tx_body
    ])
    ^cardano-cli latest transaction build ...($build_args | append $net)
    ^cardano-cli latest transaction sign --tx-body-file $f_tx_body --signing-key-file $f_skey --out-file $f_tx_signed
    let txid = (confirm-and-submit $f_tx_signed $net)
    rm --force $f_tx_body $f_tx_signed
    if $txid == null {
      rm --force $f_skey
      return
    }
    wait-for-tx $txid $net
    print $"(ansi green)Pass 2 complete! TxID: ($txid)(ansi reset)"
    print $"  Consolidated ($token_count) native token UTxOs into 1."
  }
  # Clean up
  rm --force $f_skey
  print $"\n(ansi green)Defrag complete at ($address)(ansi reset)"
}
