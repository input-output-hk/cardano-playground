#!/usr/bin/env nu
# tx-firehose fund management
#
# Funds a firehose address, reports what it holds and how long that lasts, and
# sweeps it back when it gets low.
#
# Every transaction returns its inputs less the fixed fee to the same address,
# so the fee is the entire burn rate and the balance falls linearly.
#
# Stop cardano-tx-firehose before defunding, or work during an odd hour when
# the window is closed. A running firehose spends the UTxO the sweep is built
# against and the sweep then fails as AllInputsAreSpent.
#
# Nothing is submitted by default: each transaction is built and signed and
# left in the directory the script was called from. --submit submits behind a
# y/N prompt.
#
# Environment variables provided by the playground devShell:
#   TESTNET_MAGIC            Cardano testnet magic number
#   CARDANO_NODE_SOCKET_PATH Path to a running cardano-node socket
#
# Usage, from the repo root inside the devShell:
#   firehose-funds.nu fund   <key-path> [--lovelace <n>] [--submit]
#   firehose-funds.nu status <key-path> [--tps <n>] [--fee <lovelace>]
#   firehose-funds.nu defund <key-path> [--submit]
#
# Paths are given without an extension, with .addr and .skey beside each other
# and sops-encrypted. key-path is the firehose key, e.g.
# secrets/groups/leios2/deploy/leios2-rel-b-2-firehose-fund
#
# Funding flows to and from --funding-key, which defaults to the rich key of
# --environment or of ENV:
#
#   ENV=leios firehose-funds.nu fund <key-path> --submit

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
def net-args [] {
  if ("TESTNET_MAGIC" not-in $env) {
    error make --unspanned {msg: "TESTNET_MAGIC is not set. Are you inside the playground devShell?"}
  }
  [
    "--testnet-magic"
    $env.TESTNET_MAGIC
  ]
}

# leios-pin.sh and node-local-pin.sh prepend a symlink dir to PATH, but a
# `nix develop -c` or a direnv reload rebuilds PATH from the devShell and drops
# that prepend while the pin's marker variable survives.
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
  for p in $pins { $env.PATH = ($env.PATH | where {|d| $d != $p.dir} | prepend $p.dir) }
  $pins | get dir
}

# `latest` is an alias for the newest stable era, so it silently builds a
# Conway tx against a Dijkstra node and the node rejects it.
def era-group [tip_era: string]: nothing -> string {
  let era = $tip_era | str downcase
  if (^cardano-cli $era --help | complete | get exit_code) != 0 {
    error make --unspanned {
      msg: $"cardano-cli has no '($era)' era command group, but the node is in the ($tip_era) era. Pin a cardano-cli that knows it, e.g. with scripts/playground/leios-pin.sh or node-local-pin.sh."
    }
  }
  $era
}

def report-tooling [] {
  let cli = which cardano-cli | get --optional path.0
  if ($cli | is-empty) {
    error make --unspanned {msg: "cardano-cli not found on PATH. Are you inside the playground devShell?"}
  }
  print $"  cardano-cli: ($cli)"
  print $"  version:     (^cardano-cli --version | lines | first | str trim)"
}

# ─── Address and UTxO ─────────────────────────────────────────────────────────
# The address tx-firehose derives from the same key. Enterprise unless a stake
# key is given, matching services.cardano-tx-firehose.stakingKeyFile.
def derive-address [
  skey_file: string
  --staking-key-path: string = ""
  --net-args: list<string>
]: nothing -> string {
  let f_skey = (^mktemp --suffix .skey | str trim)
  let f_vkey_raw = (^mktemp --suffix .vkey | str trim)
  let f_vkey = (^mktemp --suffix .vkey | str trim)
  let f_addr = (^mktemp --suffix .addr | str trim)

  (sops-decrypt $skey_file) | save --force $f_skey
  ^cardano-cli latest key verification-key --signing-key-file $f_skey --verification-key-file $f_vkey_raw

  let vkey_json = (open --raw $f_vkey_raw | from json)
  if ($vkey_json.type | str contains "Extended") {
    ^cardano-cli latest key non-extended-key --extended-verification-key-file $f_vkey_raw --verification-key-file $f_vkey
  } else {
    cp $f_vkey_raw $f_vkey
  }

  let stake_args = if ($staking_key_path | is-empty) { [] } else {
    let f_stake_skey = (^mktemp --suffix .skey | str trim)
    let f_stake_vkey = (^mktemp --suffix .vkey | str trim)
    (sops-decrypt $"($staking_key_path).skey") | save --force $f_stake_skey
    ^cardano-cli latest key verification-key --signing-key-file $f_stake_skey --verification-key-file $f_stake_vkey
    rm --force $f_stake_skey
    ["--stake-verification-key-file" $f_stake_vkey]
  }

  ^cardano-cli latest address build --payment-verification-key-file $f_vkey ...$stake_args ...$net_args --out-file $f_addr
  let address = (open --raw $f_addr | str trim)

  rm --force $f_skey $f_vkey_raw $f_vkey $f_addr
  if not ($stake_args | is-empty) { rm --force ($stake_args | last) }
  $address
}

def query-utxos [address: string, --net-args: list<string>, --era: string]: nothing -> list<record> {
  let data = (^cardano-cli $era query utxo --address $address --output-json ...$net_args | from json)
  if ($data | is-empty) { [] } else {
    $data | transpose key value | each { |row| { txin: $row.key, lovelace: $row.value.value.lovelace } }
  }
}

# The key funding flows to and from, as a path with no extension; .addr and
# .skey sit beside each other. Defaults to the environment's rich key.
def resolve-funding [funding_key: string = "", environment: string = ""]: nothing -> record {
  let base = if not ($funding_key | is-empty) {
    $funding_key
  } else {
    let env_name = if not ($environment | is-empty) {
      $environment
    } else if ("ENV" in $env) {
      $env.ENV
    } else {
      ""
    }

    if ($env_name | is-empty) {
      error make --unspanned {
        msg: "No funding key. Pass --funding-key <path>, or --environment <env>, or set ENV."
      }
    }

    $"secrets/envs/($env_name)/utxo-keys/rich-utxo"
  }

  if not ($"($base).addr" | path exists) {
    error make --unspanned {
      msg: $"No address at ($base).addr. Run from the repo root, or pass --funding-key <path>."
    }
  }

  {base: $base, address: (sops-decrypt $"($base).addr" | str trim)}
}

# Inputs covering target plus a fee allowance, largest first so a funded
# address with many small UTxOs does not build an oversized transaction.
def select-inputs [utxos: list<record>, target: int]: nothing -> list<record> {
  let needed = $target + 5_000_000
  mut chosen = []
  mut total = 0
  for u in ($utxos | sort-by lovelace --reverse) {
    if $total >= $needed { break }
    $chosen = ($chosen | append $u)
    $total = $total + $u.lovelace
  }
  if $total < $needed {
    error make --unspanned {
      msg: $"Funding address holds ($total) lovelace, short of ($needed) for this transfer."
    }
  }
  $chosen
}

# Leave the signed tx for inspection, or view, confirm and submit it.
def submit-or-report [
  tx_file: string
  submit: bool
  --era: string
  --net-args: list<string>
  --label: string
] {
  if not $submit {
    print $"\n  Signed tx written to: ($tx_file)"
    print $"    inspect: cardano-cli debug transaction view --tx-file ($tx_file)"
    print $"    submit:  cardano-cli ($era) transaction submit --tx-file ($tx_file) ($net_args | str join ' ')"
    return
  }

  print "\n  Transaction view:"
  print (^cardano-cli debug transaction view --tx-file $tx_file --output-json)
  let response = (input "\n  Submit this transaction? [y/N] ")
  if ($response | str downcase | str trim) != "y" {
    print $"(ansi yellow)Transaction cancelled.(ansi reset)"
    rm --force $tx_file
    return
  }

  ^cardano-cli $era transaction submit --tx-file $tx_file ...$net_args
  let txid = (^cardano-cli $era transaction txid --tx-file $tx_file --output-text | str trim)
  rm --force $tx_file
  print $"\n(ansi green)($label). TxID: ($txid)(ansi reset)"
}

# Shared preflight: resolve tooling, check the node, derive the address.
def preflight [
  key_path: string
  --staking-key-path: string = ""
]: nothing -> record {
  print "Resolving cardano tooling..."
  let pinned = respect-pins
  if not ($pinned | is-empty) {
    print $"  pin active:  ($pinned | str join ', ')"
  }
  report-tooling

  let skey_file = $"($key_path).skey"
  if not ($skey_file | path exists) {
    error make --unspanned {msg: $"Signing key not found: ($skey_file)"}
  }

  let net = (net-args)
  let tip_json = try {
    ^cardano-cli query tip ...$net | from json
  } catch {
    error make --unspanned {msg: "Cannot connect to cardano-node. Is the node running and CARDANO_NODE_SOCKET_PATH set correctly?"}
  }
  let era = era-group ($tip_json | get era)
  print $"  era group:   ($era)"

  let sync_pct = ($tip_json | get syncProgress | into float)
  if $sync_pct < 100.0 {
    error make --unspanned {
      msg: $"Node is only ($sync_pct)% synced. Wait for it to reach 100% before touching firehose funds."
    }
  }

  let address = (derive-address $skey_file --staking-key-path $staking_key_path --net-args $net)
  print $"\n  Address: ($address)"

  {skey_file: $skey_file, net: $net, era: $era, address: $address}
}

def main []: nothing -> nothing { }

# Report the balance and how much load it still buys
def 'main status' [
  key_path: string           # Path without the .skey extension, sops-encrypted
  --staking-key-path: string = "" # Stake key path without .skey, when the module sets stakingKeyFile
  --tps: int = 100           # Rate the estimate assumes
  --fee: int = 200000        # services.cardano-tx-firehose.fee
] {
  let pre = (preflight $key_path --staking-key-path $staking_key_path)
  let utxos = (query-utxos $pre.address --net-args $pre.net --era $pre.era)

  if ($utxos | is-empty) {
    print $"\n(ansi red)No UTxO at this address. tx-firehose will exit on startup until it is funded.(ansi reset)"
    return
  }

  let total = ($utxos | each { |u| $u.lovelace } | math sum)
  print $"\n  UTxOs: ($utxos | length)"
  for u in $utxos {
    print $"    ($u.txin)  (lovelace-to-ada $u.lovelace)"
  }
  print $"  Total: (lovelace-to-ada $total)"

  # Every tx spends the fee and returns the rest, so runway is total over fee.
  let txs = ($total // $fee)
  let load_hours = ($txs / $tps / 3600)
  print $"\n  At ($tps) tps and a fee of (lovelace-to-ada $fee):"
  print $"    transactions remaining: (comma-sep $txs)"
  print $"    hours of load:          ($load_hours | math round --precision 1)"
  # The default calendars give a 50% duty cycle, so 12 load hours per day.
  print $"    days on the even hour window: ($load_hours / 12 | math round --precision 1)"
}

# Send a single large UTxO to the firehose address
def 'main fund' [
  key_path: string                       # Path without the .skey extension, sops-encrypted
  --funding-key: string = ""                  # Funding key without extension; defaults to the environment's rich key
  --environment: string = ""                  # Environment whose rich key to fund from; defaults to $ENV
  --lovelace: int = 30000000000000       # Total amount to send, 30M ada by default
  --utxo-count: int = 50                 # Outputs to split it across
  --staking-key-path: string = ""             # Stake key path without .skey, when the module sets stakingKeyFile
  --submit                               # Submit after confirmation; default builds and signs only
] {
  if $utxo_count < 1 {
    error make --unspanned {msg: "--utxo-count must be >= 1"}
  }
  let funding = (resolve-funding $funding_key $environment)
  let stamp = date now | format date "%Y%m%d-%H%M%S"
  let pre = (preflight $key_path --staking-key-path $staking_key_path)

  print $"\n  Funding: ($funding.base)"
  let src_utxos = (query-utxos $funding.address --net-args $pre.net --era $pre.era)
  if ($src_utxos | is-empty) {
    error make --unspanned {msg: $"Funding address holds no UTxO: ($funding.base).addr"}
  }

  let inputs = (select-inputs $src_utxos $lovelace)
  let each_out = $lovelace // $utxo_count
  print $"  Spending ($inputs | length) of ($src_utxos | length) funding UTxOs"
  print $"  Sending (lovelace-to-ada $lovelace) to ($pre.address) as ($utxo_count) outputs of (lovelace-to-ada $each_out)"
  print "\n  Split on purpose. tx-firehose spends one fund per transaction and drops the inputs on an AllInputsAreSpent reject, so a single UTxO drains the set on the first reject and the run exits. The split is how many rejects it survives."

  let f_skey = (^mktemp --suffix .skey | str trim)
  (sops-decrypt $"($funding.base).skey") | save --force $f_skey

  let f_tx_body = (^mktemp --suffix .txbody | str trim)
  let f_tx_signed = if $submit {
    ^mktemp --suffix .tx | str trim
  } else {
    $env.PWD | path join $"firehose-fund-($stamp).txsigned"
  }

  try {
    let out_args = (1..$utxo_count | each { ["--tx-out" $"($pre.address)+($each_out)"] } | flatten)
    let build_args = ($inputs | each { |u| ["--tx-in" $u.txin] } | flatten | append $out_args | append [
      "--change-address"
      $funding.address
      "--witness-override"
      "1"
      "--out-file"
      $f_tx_body
    ])
    ^cardano-cli $pre.era transaction build ...$build_args ...$pre.net
    ^cardano-cli $pre.era transaction sign --tx-body-file $f_tx_body --signing-key-file $f_skey --out-file $f_tx_signed
  } catch {|e|
    rm --force $f_skey $f_tx_body
    error make --unspanned {msg: $"Funding build failed: ($e.msg)"}
  }
  rm --force $f_skey $f_tx_body

  submit-or-report $f_tx_signed $submit --era $pre.era --net-args $pre.net --label "Funded"
}

# Sweep every UTxO back to the funding address
def 'main defund' [
  key_path: string           # Path without the .skey extension, sops-encrypted
  --funding-key: string = ""      # Funding key without extension; defaults to the environment's rich key
  --environment: string = ""      # Environment whose rich key to sweep to; defaults to $ENV
  --staking-key-path: string = "" # Stake key path without .skey, when the module sets stakingKeyFile
  --submit                   # Submit after confirmation; default builds and signs only
] {
  let dest = (resolve-funding $funding_key $environment)

  let stamp = date now | format date "%Y%m%d-%H%M%S"
  let pre = (preflight $key_path --staking-key-path $staking_key_path)
  let utxos = (query-utxos $pre.address --net-args $pre.net --era $pre.era)

  if ($utxos | is-empty) {
    print $"\n(ansi yellow)Nothing to sweep, the address holds no UTxO.(ansi reset)"
    return
  }

  let total = ($utxos | each { |u| $u.lovelace } | math sum)
  print $"\n  Sweeping ($utxos | length) UTxOs, (lovelace-to-ada $total) less fee"
  for u in $utxos {
    print $"    ($u.txin)  (lovelace-to-ada $u.lovelace)"
  }
  print $"  To: ($dest.address)"
  print $"  Funding key: ($dest.base)"
  print $"\n(ansi yellow)Stop cardano-tx-firehose first. A running firehose spends these inputs and the sweep fails as AllInputsAreSpent.(ansi reset)"

  let f_skey = (^mktemp --suffix .skey | str trim)
  (sops-decrypt $pre.skey_file) | save --force $f_skey

  let f_tx_body = (^mktemp --suffix .txbody | str trim)
  let f_tx_signed = if $submit {
    ^mktemp --suffix .tx | str trim
  } else {
    $env.PWD | path join $"firehose-defund-($stamp).txsigned"
  }

  try {
    let build_args = ($utxos | each { |u| ["--tx-in" $u.txin] } | flatten | append [
      "--change-address"
      $dest.address
      "--witness-override"
      "1"
      "--out-file"
      $f_tx_body
    ])
    ^cardano-cli $pre.era transaction build ...$build_args ...$pre.net
    ^cardano-cli $pre.era transaction sign --tx-body-file $f_tx_body --signing-key-file $f_skey --out-file $f_tx_signed
  } catch {|e|
    rm --force $f_skey $f_tx_body
    error make --unspanned {msg: $"Sweep build failed: ($e.msg)"}
  }
  rm --force $f_skey $f_tx_body

  submit-or-report $f_tx_signed $submit --era $pre.era --net-args $pre.net --label "Swept"
}
