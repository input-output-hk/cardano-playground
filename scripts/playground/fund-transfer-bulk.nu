#!/usr/bin/env nu
# Cardano Bulk Funding Tool
#
# Transfers lovelace from a single sops-encrypted payment key to multiple
# recipients in one transaction.  Amounts are specified in lovelace; the
# summary table displays the equivalent ADA for review.
# Only lovelace-only UTxOs are used as inputs — native token UTxOs are untouched.
#
# Private key material is written only to short-lived mktemp files that are
# deleted immediately after use.
#
# ENVIRONMENT VARIABLES (provided by the playground devShell):
#   TESTNET_MAGIC            Cardano testnet magic number
#   CARDANO_NODE_SOCKET_PATH Path to the running cardano-node socket
#
# USAGE (run from repo root inside the devShell):
#   fund-transfer-bulk.nu <environment> <key-path> [--file <path>] [--dry-run] [pairs...]
#
# ARGUMENTS:
#   environment  Playground environment: preview, preprod, etc.
#   key-path     Path and filename without the .skey extension (sops-encrypted).
#   pairs        Alternating address and lovelace amount, e.g.:
#                  addr_test1qz... 100000000 addr_test1qp... 50500000
#
# OPTIONS:
#   --file (-f)  Path to a transfers file (one "address lovelace" per line).
#                Lines starting with # and blank lines are ignored.
#   --dry-run    Show the transfer plan without building or submitting.
#
# EXAMPLES:
#   # Inline pairs (amounts in lovelace):
#   fund-transfer-bulk.nu preview secrets/envs/preview/utxo-keys/rich-utxo \
#     addr_test1qz... 100000000 addr_test1qp... 50500000
#
#   # From a file:
#   fund-transfer-bulk.nu preview secrets/envs/preview/utxo-keys/rich-utxo \
#     --file transfers.txt
#
#   # transfers.txt format (amounts in lovelace):
#   #   # comment lines and blank lines are ignored
#   #   addr_test1qz...  100000000
#   #   addr_test1qp...  50500000

# ─── SOPS helpers ─────────────────────────────────────────────────────────────

def sops-config [file: string] {
    mut dir = if ($file | str starts-with '/') {
        $file | path dirname
    } else {
        [$env.PWD, ($file | path dirname)] | path join
    }
    loop {
        if ($"($dir)/.sops.yaml" | path exists) { return $"($dir)/.sops.yaml" }
        let parent = ($dir | path dirname)
        if $parent == $dir {
            error make --unspanned { msg: $"No .sops.yaml found above ($file)" }
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
    let whole       = ($lovelace // 1_000_000)
    let frac        = ($lovelace mod 1_000_000)
    let frac_padded = ($frac | into string | fill --width 6 --character '0' --alignment right)
    $"(comma-sep $whole).($frac_padded) ADA"
}

# Parse and validate a lovelace amount string
def parse-lovelace [amount: string] {
    let lovelace = try {
        $amount | into int
    } catch {
        error make --unspanned { msg: $"Invalid lovelace amount: '($amount)' — must be a whole number" }
    }
    if $lovelace <= 0 {
        error make --unspanned { msg: $"Amount must be positive, got: ($amount) lovelace" }
    }
    $lovelace
}

# ─── Network helpers ──────────────────────────────────────────────────────────

def expected-magic [environment: string] {
    match $environment {
        "preview" => "2"
        "preprod" => "1"
        _ => null
    }
}

def check-network [environment: string] {
    let expected = (expected-magic $environment)
    if $expected == null { return }
    for var in ["TESTNET_MAGIC" "CARDANO_NODE_NETWORK_ID"] {
        if ($var in $env) and ($env | get $var | into string) != $expected {
            error make --unspanned { msg: $"($var) is ($env | get $var) but expected ($expected) for ($environment)" }
        }
    }
}

def net-args [] {
    if ("TESTNET_MAGIC" not-in $env) {
        error make --unspanned { msg: "TESTNET_MAGIC is not set. Are you inside the playground devShell?" }
    }
    ["--testnet-magic", $env.TESTNET_MAGIC]
}

# ─── Transfer parsing ────────────────────────────────────────────────────────

# Parse a transfers file: one "address lovelace" per line.
# Lines starting with # and blank lines are skipped.
# Separator: whitespace or comma.
def parse-transfers-file [path: string] {
    if not ($path | path exists) {
        error make --unspanned { msg: $"Transfers file not found: ($path)" }
    }
    let lines = (open --raw $path | lines)
    mut transfers = []
    for line in $lines {
        let trimmed = ($line | str trim)
        if ($trimmed | is-empty) or ($trimmed | str starts-with '#') { continue }
        # Split on comma, whitespace, or comma+whitespace
        let parts = ($trimmed | split row --regex '[,\s]+')
        if ($parts | length) != 2 {
            error make --unspanned { msg: $"Bad line in ($path): '($trimmed)'\n  Expected: <address> <lovelace>" }
        }
        let address = ($parts | get 0)
        let lovelace = (parse-lovelace ($parts | get 1))
        $transfers = ($transfers | append { address: $address, lovelace: $lovelace })
    }
    if ($transfers | is-empty) {
        error make --unspanned { msg: $"No transfers found in ($path)" }
    }
    $transfers
}

# Parse inline rest-args: alternating address amount pairs
def parse-transfers-pairs [pairs: list<string>] {
    if ($pairs | is-empty) {
        error make --unspanned { msg: "No transfer pairs provided. Supply address/amount pairs or use --file." }
    }
    if (($pairs | length) mod 2) != 0 {
        error make --unspanned { msg: "Inline pairs must alternate: <address> <amount> <address> <amount> ..." }
    }
    let count = (($pairs | length) / 2 | into int)
    mut transfers = []
    for i in 0..<$count {
        let address = ($pairs | get ($i * 2))
        let lovelace = (parse-lovelace ($pairs | get ($i * 2 + 1)))
        $transfers = ($transfers | append { address: $address, lovelace: $lovelace })
    }
    $transfers
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

# Transfer lovelace from a payment key to multiple recipients in one transaction
def main [
    environment: string     # Playground environment: preview, preprod, etc.
    key_path: string        # Path and filename without .skey extension (sops-encrypted)
    --file (-f): string     # Path to transfers file (address lovelace per line)
    --dry-run               # Show transfer plan without submitting
    ...pairs: string        # Inline address/lovelace pairs
] {
    check-network $environment

    let skey_file = $"($key_path).skey"
    if not ($skey_file | path exists) {
        error make --unspanned { msg: $"Signing key not found: ($skey_file)" }
    }

    # Parse transfers early so we fail fast on bad input
    let transfers = if $file != null {
        if not ($pairs | is-empty) {
            error make --unspanned { msg: "Provide transfers via --file or inline pairs, not both." }
        }
        parse-transfers-file $file
    } else {
        parse-transfers-pairs $pairs
    }

    let net = (net-args)

    # Verify node is reachable and fully synced
    print $"Checking node connectivity and sync status on environment ($environment)..."
    let tip_json = try {
        ^cardano-cli latest query tip ...$net | from json
    } catch {
        error make --unspanned { msg: "Cannot connect to cardano-node. Is the node running and CARDANO_NODE_SOCKET_PATH set correctly?" }
    }
    print ($tip_json | to json --indent 2)
    let sync_pct = ($tip_json | get syncProgress | into float)
    if $sync_pct < 100.0 {
        error make --unspanned { msg: $"Node is only ($sync_pct)% synced. Wait for it to reach 100% before transferring funds." }
    }

    # Decrypt the signing key and derive the source address
    print $"\nDecrypting signing key for ($environment)..."
    let skey_content = (sops-decrypt $skey_file)

    let f_skey     = (^mktemp --suffix .skey | str trim)
    let f_vkey_raw = (^mktemp --suffix .vkey | str trim)
    let f_vkey     = (^mktemp --suffix .vkey | str trim)
    let f_addr     = (^mktemp --suffix .addr | str trim)
    $skey_content | save --force $f_skey

    ^cardano-cli latest key verification-key --signing-key-file $f_skey --verification-key-file $f_vkey_raw

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

    # Query source UTxOs (lovelace-only inputs only)
    print $"\nQuerying source UTxOs..."

    let all_data = (^cardano-cli latest query utxo --address $address --output-json ...$net | from json)
    let all_utxos = if ($all_data | is-empty) { [] } else { $all_data | transpose key value }
    let lovelace_utxos = ($all_utxos
        | where { |row| ($row.value.value | columns | length) == 1 }
        | each  { |row| { txin: $row.key, lovelace: $row.value.value.lovelace } })
    let available = if ($lovelace_utxos | is-empty) { 0 } else { $lovelace_utxos | each { |u| $u.lovelace } | math sum }
    let token_count = ($all_utxos | length) - ($lovelace_utxos | length)

    print $"  Available balance: (lovelace-to-ada $available)  \(($lovelace_utxos | length) lovelace-only UTxOs\)"
    if $token_count > 0 {
        print $"  Native token UTxOs: ($token_count) \(untouched\)"
    }

    # Display transfer plan
    let total_lovelace = ($transfers | each { |t| $t.lovelace } | math sum)
    let recipient_count = ($transfers | length)

    let rows = ($transfers | each { |t|
        {
            "Address": $t.address
            "Amount": (lovelace-to-ada $t.lovelace)
        }
    })

    print $"\nTransfers:"
    print ($rows | table)
    print $"  Total: (lovelace-to-ada $total_lovelace)  \(($recipient_count) recipient\(s\)\)"

    if $total_lovelace > $available {
        rm --force $f_skey
        error make --unspanned { msg: $"Insufficient funds: need (lovelace-to-ada $total_lovelace) but only (lovelace-to-ada $available) available in lovelace-only UTxOs." }
    }

    if $dry_run {
        print $"\n(ansi yellow)Dry run — no transaction submitted.(ansi reset)"
        rm --force $f_skey
        return
    }

    # Build the transaction
    print "\nBuilding transaction..."
    let f_tx_body   = (^mktemp --suffix .txbody | str trim)
    let f_tx_signed = (^mktemp --suffix .tx     | str trim)

    mut build_args: list<string> = []
    for utxo in $lovelace_utxos {
        $build_args = ($build_args | append ["--tx-in", $utxo.txin])
    }
    for transfer in $transfers {
        $build_args = ($build_args | append ["--tx-out", $"($transfer.address)+($transfer.lovelace)"])
    }
    $build_args = ($build_args | append [
        "--change-address", $address,
        "--witness-override", "1",
        "--out-file", $f_tx_body,
    ])

    ^cardano-cli latest transaction build ...($build_args | append $net)

    # Sign
    ^cardano-cli latest transaction sign --tx-body-file $f_tx_body --signing-key-file $f_skey --out-file $f_tx_signed

    # Confirm and submit
    let txid = (confirm-and-submit $f_tx_signed $net)

    # Clean up
    rm --force $f_skey $f_tx_body $f_tx_signed

    if $txid == null { return }

    wait-for-tx $txid $net
    print $"(ansi green)Transfer complete! TxID: ($txid)(ansi reset)"
    print $"  Sent (lovelace-to-ada $total_lovelace) to ($recipient_count) recipient\(s\) from ($address)"
}
