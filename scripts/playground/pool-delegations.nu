#!/usr/bin/env nu
# Cardano Pool Delegation Manager
#
# Derives stake keys and payment addresses from a BIP39 mnemonic and provides
# tools to view and manage testnet pool delegations on Cardano.
#
# KEY DERIVATION (CIP-1852):
#   root -> m/1852'/1815'/0' (account) -> 0/i (payment), 2/i (staking)
#
# SECRETS LAYOUT (relative to repo root):
#   secrets/envs/<env>/pool-delegations/
#     pool-delegations.mnemonic        24-word BIP39 mnemonic
#     <i>/
#       payment.addr                   Payment-only address
#       stake.addr                     Stake address
#       delegation.addr                Combined payment+stake (fund this one)
#
# ENVIRONMENT VARIABLES (provided by the playground devShell):
#   TESTNET_MAGIC            Cardano testnet magic number
#   CARDANO_NODE_SOCKET_PATH Path to the running cardano-node socket
#   CARDANO_NODE_NETWORK_ID  Network ID (mirrors TESTNET_MAGIC)
#
# USAGE (run from repo root inside the devShell):
#   pool-delegations.nu generate   <env> [-n N]
#   pool-delegations.nu status     <env> [-n N]
#   pool-delegations.nu address    <env> -i I
#   pool-delegations.nu delegate   <env> -p <pool1...> -i I [--dry-run]
#   pool-delegations.nu dedelegate <env> -i I [--dry-run]
#   pool-delegations.nu deregister <env> -i I [--dry-run]
#   pool-delegations.nu defund     <env> -d <addr> -i I [--dry-run]

const ACCOUNT_PATH = "1852H/1815H/0H"

# ─── Paths ────────────────────────────────────────────────────────────────────

def secrets-root [environment: string] {
    $"secrets/envs/($environment)/pool-delegations"
}

def mnemonic-path [environment: string] {
    $"(secrets-root $environment)/pool-delegations.mnemonic"
}

def account-dir [environment: string, index: int] {
    $"(secrets-root $environment)/($index)"
}

# Count existing numbered account directories under the secrets tree
def count-accounts [environment: string] {
    let root = (secrets-root $environment)
    if not ($root | path exists) { return 0 }
    ls $root | where type == dir | where { |d| ($d.name | path basename) =~ '^\d+$' } | length
}

# Resolve the environment: explicit arg > $ENV env var > error
def resolve-env [environment?: string] {
    if $environment != null {
        $environment
    } else if ("ENV" in $env) {
        $env.ENV
    } else {
        error make { msg: "Provide an <environment> argument (e.g. \"preview\") or set the ENV environment variable" }
    }
}

# Read and validate the mnemonic for the given environment
def read-mnemonic [environment: string] {
    let path = (mnemonic-path $environment)
    if not ($path | path exists) {
        error make { msg: $"Mnemonic not found: ($path)\n  Create it with:\n    mkdir -p (secrets-root $environment)\n    echo '<24 words>' | save ($path)" }
    }
    open --raw $path | str trim
}

# ─── Display helpers ──────────────────────────────────────────────────────────

# Insert commas every 3 digits from the right (e.g. 10000000 -> "10,000,000")
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

def trunc-addr [addr: string, len: int = 28] {
    if ($addr | str length) <= $len { $addr } else {
        $"($addr | str substring 0..$len)..."
    }
}

# ─── Network helpers ──────────────────────────────────────────────────────────

# Expected TESTNET_MAGIC for known environments
def expected-magic [environment: string] {
    match $environment {
        "preview" => "2"
        "preprod" => "1"
        _ => null
    }
}

# Sanity-check that TESTNET_MAGIC and CARDANO_NODE_NETWORK_ID match the environment
def check-network [environment: string] {
    let expected = (expected-magic $environment)
    if $expected == null { return }
    for var in ["TESTNET_MAGIC" "CARDANO_NODE_NETWORK_ID"] {
        if ($var in $env) and ($env | get $var | into string) != $expected {
            error make { msg: $"($var) is ($env | get $var) but expected ($expected) for ($environment)" }
        }
    }
}

# Always testnet -- reads TESTNET_MAGIC from the devShell environment.
def net-args [] {
    if ("TESTNET_MAGIC" not-in $env) {
        error make { msg: "TESTNET_MAGIC is not set. Are you inside the playground devShell?" }
    }
    ["--testnet-magic", $env.TESTNET_MAGIC]
}

# ─── Key derivation ───────────────────────────────────────────────────────────

def root-key [mnemonic: string] {
    $mnemonic | ^cardano-address key from-recovery-phrase Shelley | str trim
}

def account-skey [root_skey: string] {
    $root_skey | ^cardano-address key child $ACCOUNT_PATH | str trim
}

# Derive all keys and addresses for account index i (always testnet)
def derive-account [account_skey: string, index: int] {
    let pay_xsk    = ($account_skey | ^cardano-address key child $"0/($index)" | str trim)
    let stake_xsk  = ($account_skey | ^cardano-address key child $"2/($index)" | str trim)
    let pay_vext   = ($pay_xsk   | ^cardano-address key public --with-chain-code | str trim)
    let stake_vext = ($stake_xsk | ^cardano-address key public --with-chain-code | str trim)

    let pay_addr   = ($pay_vext   | ^cardano-address address payment   --network-tag testnet | str trim)
    let stake_addr = ($stake_vext | ^cardano-address address stake      --network-tag testnet | str trim)
    let deleg_addr = ($pay_addr   | ^cardano-address address delegation $stake_vext          | str trim)

    {
        index:              $index
        pay_xsk:            $pay_xsk
        stake_xsk:          $stake_xsk
        pay_vext:           $pay_vext
        stake_vext:         $stake_vext
        payment_address:    $pay_addr
        stake_address:      $stake_addr
        delegation_address: $deleg_addr
    }
}

# ─── CLI key conversion ───────────────────────────────────────────────────────

# Convert a cardano-address extended signing key to cardano-cli JSON format.
# key_type: "shelley-payment-key" | "shelley-stake-key"
def to-cli-skey [xsk: string, key_type: string] {
    let f_in  = (^mktemp | str trim)
    let f_out = (^mktemp | str trim)
    $xsk | save --force $f_in
    let args = [$"--($key_type)", "--signing-key-file", $f_in, "--out-file", $f_out]
    ^cardano-cli latest key convert-cardano-address-key ...$args
    let result = (open --raw $f_out | str trim)
    rm --force $f_in $f_out
    $result
}

# Get non-extended CLI verification key JSON from CLI signing key JSON
def to-cli-vkey [skey_json: string] {
    let f_skey     = (^mktemp --suffix .skey | str trim)
    let f_vkey_ext = (^mktemp --suffix .vkey | str trim)
    let f_vkey     = (^mktemp --suffix .vkey | str trim)
    $skey_json | save --force $f_skey
    ^cardano-cli latest key verification-key --signing-key-file $f_skey --verification-key-file $f_vkey_ext
    ^cardano-cli latest key non-extended-key --extended-verification-key-file $f_vkey_ext --verification-key-file $f_vkey
    let result = (open --raw $f_vkey | str trim)
    rm --force $f_skey $f_vkey_ext $f_vkey
    $result
}

# ─── Chain queries ────────────────────────────────────────────────────────────

# Returns {registered, delegation, rewards}
def query-stake-info [stake_addr: string, net_args: list<string>] {
    let data = (^cardano-cli latest query stake-address-info --address $stake_addr ...$net_args | from json)
    if ($data | is-empty) {
        { registered: false, delegation: null, rewards: 0 }
    } else {
        let info = ($data | first)
        # Conway era: stakeDelegation is a record with stakePoolBech32/stakePoolHex
        # Older eras: delegation is a plain pool ID string
        let sd = ($info | get -o stakeDelegation)
        let pool = if $sd != null and ($sd | describe | str starts-with 'record') {
            $sd | get -o stakePoolBech32
        } else if $sd != null {
            $sd
        } else {
            $info | get -o delegation
        }
        {
            registered: true
            delegation: $pool
            rewards:    ($info.rewardAccountBalance? | default 0)
        }
    }
}

# Returns total lovelace balance at address (all UTxOs summed)
def query-balance [address: string, net_args: list<string>] {
    let data = (^cardano-cli latest query utxo --address $address --output-json ...$net_args | from json)
    if ($data | is-empty) { return 0 }
    $data | transpose key value
          | each { |row| $row.value.value.lovelace? | default 0 }
          | math sum
}

# Returns the largest lovelace-only UTxO as {txin, lovelace}
def largest-lovelace-utxo [address: string, net_args: list<string>] {
    let data = (^cardano-cli latest query utxo --address $address --output-json ...$net_args | from json)
    let utxos = ($data | transpose key value
        | where { |row| ($row.value.value | columns | length) == 1 }
        | each  { |row| { txin: $row.key, lovelace: $row.value.value.lovelace } }
        | sort-by lovelace --reverse)
    if ($utxos | is-empty) {
        error make { msg: $"No lovelace-only UTxO found at ($address)" }
    }
    $utxos | first
}

# Returns all UTxO txins at an address as a list of strings
def all-utxo-txins [address: string, net_args: list<string>] {
    let data = (^cardano-cli latest query utxo --address $address --output-json ...$net_args | from json)
    if ($data | is-empty) { return [] }
    $data | transpose key value | each { |row| $row.key }
}

# Poll mempool every 5 seconds until a transaction clears
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

# ─── Transactions ─────────────────────────────────────────────────────────────

# Register stake key (if needed) and delegate to pool.
# Signs with both the payment key and stake key derived from the account mnemonic.
def tx-delegate [
    acct: record
    pool_id: string
    net_args: list<string>
    registered: bool          # true = already on-chain, skip registration cert
] {
    let pay_skey_json   = (to-cli-skey $acct.pay_xsk   "shelley-payment-key")
    let stake_skey_json = (to-cli-skey $acct.stake_xsk "shelley-stake-key")
    let stake_vkey_json = (to-cli-vkey $stake_skey_json)

    let f_pay_skey   = (^mktemp --suffix .skey   | str trim)
    let f_stake_skey = (^mktemp --suffix .skey   | str trim)
    let f_stake_vkey = (^mktemp --suffix .vkey   | str trim)
    let f_reg_cert   = (^mktemp --suffix .cert   | str trim)
    let f_deleg_cert = (^mktemp --suffix .cert   | str trim)
    let f_tx_body    = (^mktemp --suffix .txbody | str trim)
    let f_tx_signed  = (^mktemp --suffix .tx     | str trim)

    $pay_skey_json   | save --force $f_pay_skey
    $stake_skey_json | save --force $f_stake_skey
    $stake_vkey_json | save --force $f_stake_vkey

    let pparams = (^cardano-cli latest query protocol-parameters ...$net_args | from json)
    let deposit = ($pparams | get stakeAddressDeposit)
    let utxo    = (largest-lovelace-utxo $acct.delegation_address $net_args)

    mut cert_args: list<string> = []

    if not $registered {
        ^cardano-cli latest stake-address registration-certificate --stake-verification-key-file $f_stake_vkey --key-reg-deposit-amt ($deposit | into string) --out-file $f_reg_cert
        $cert_args = ($cert_args | append ["--certificate-file", $f_reg_cert])
    }

    ^cardano-cli latest stake-address stake-delegation-certificate --stake-verification-key-file $f_stake_vkey --stake-pool-id $pool_id --out-file $f_deleg_cert
    $cert_args = ($cert_args | append ["--certificate-file", $f_deleg_cert])

    let build_args = (["--tx-in", $utxo.txin, "--change-address", $acct.delegation_address, "--witness-override", "2"]
        | append $cert_args
        | append ["--out-file", $f_tx_body]
        | append $net_args)
    ^cardano-cli latest transaction build ...$build_args

    ^cardano-cli latest transaction sign --tx-body-file $f_tx_body --signing-key-file $f_pay_skey --signing-key-file $f_stake_skey --out-file $f_tx_signed
    ^cardano-cli latest transaction submit --tx-file $f_tx_signed ...$net_args

    let txid = (^cardano-cli latest transaction txid --tx-file $f_tx_signed --output-text | str trim)
    rm --force $f_pay_skey $f_stake_skey $f_stake_vkey $f_reg_cert $f_deleg_cert $f_tx_body $f_tx_signed
    wait-for-tx $txid $net_args
    $txid
}

# Remove pool delegation but keep the stake key registered.
# Submits deregistration + re-registration in one tx (net zero deposit).
def tx-dedelegate [acct: record, net_args: list<string>] {
    let pay_skey_json   = (to-cli-skey $acct.pay_xsk   "shelley-payment-key")
    let stake_skey_json = (to-cli-skey $acct.stake_xsk "shelley-stake-key")
    let stake_vkey_json = (to-cli-vkey $stake_skey_json)

    let f_pay_skey   = (^mktemp --suffix .skey   | str trim)
    let f_stake_skey = (^mktemp --suffix .skey   | str trim)
    let f_stake_vkey = (^mktemp --suffix .vkey   | str trim)
    let f_dereg_cert = (^mktemp --suffix .cert   | str trim)
    let f_reg_cert   = (^mktemp --suffix .cert   | str trim)
    let f_tx_body    = (^mktemp --suffix .txbody | str trim)
    let f_tx_signed  = (^mktemp --suffix .tx     | str trim)

    $pay_skey_json   | save --force $f_pay_skey
    $stake_skey_json | save --force $f_stake_skey
    $stake_vkey_json | save --force $f_stake_vkey

    let pparams    = (^cardano-cli latest query protocol-parameters ...$net_args | from json)
    let deposit    = ($pparams | get stakeAddressDeposit)
    let stake_info = (query-stake-info $acct.stake_address $net_args)
    let utxo       = (largest-lovelace-utxo $acct.delegation_address $net_args)

    # Deregister (refunds deposit) then re-register (pays deposit) = net zero
    ^cardano-cli latest stake-address deregistration-certificate --stake-verification-key-file $f_stake_vkey --key-reg-deposit-amt ($deposit | into string) --out-file $f_dereg_cert
    ^cardano-cli latest stake-address registration-certificate --stake-verification-key-file $f_stake_vkey --key-reg-deposit-amt ($deposit | into string) --out-file $f_reg_cert

    mut tx_args: list<string> = [
        "--tx-in",            $utxo.txin,
        "--change-address",   $acct.delegation_address,
        "--certificate-file", $f_dereg_cert,
        "--certificate-file", $f_reg_cert,
        "--witness-override", "2",
        "--out-file",         $f_tx_body,
    ]
    if $stake_info.rewards > 0 {
        $tx_args = ($tx_args | append ["--withdrawal", $"($acct.stake_address)+($stake_info.rewards)"])
    }
    ^cardano-cli latest transaction build ...($tx_args | append $net_args)

    ^cardano-cli latest transaction sign --tx-body-file $f_tx_body --signing-key-file $f_pay_skey --signing-key-file $f_stake_skey --out-file $f_tx_signed
    ^cardano-cli latest transaction submit --tx-file $f_tx_signed ...$net_args

    let txid = (^cardano-cli latest transaction txid --tx-file $f_tx_signed --output-text | str trim)
    rm --force $f_pay_skey $f_stake_skey $f_stake_vkey $f_dereg_cert $f_reg_cert $f_tx_body $f_tx_signed
    wait-for-tx $txid $net_args
    $txid
}

# Deregister stake key, withdraw pending rewards, reclaim 2 ADA deposit.
def tx-deregister [acct: record, net_args: list<string>] {
    let pay_skey_json   = (to-cli-skey $acct.pay_xsk   "shelley-payment-key")
    let stake_skey_json = (to-cli-skey $acct.stake_xsk "shelley-stake-key")
    let stake_vkey_json = (to-cli-vkey $stake_skey_json)

    let f_pay_skey   = (^mktemp --suffix .skey   | str trim)
    let f_stake_skey = (^mktemp --suffix .skey   | str trim)
    let f_stake_vkey = (^mktemp --suffix .vkey   | str trim)
    let f_dereg_cert = (^mktemp --suffix .cert   | str trim)
    let f_tx_body    = (^mktemp --suffix .txbody | str trim)
    let f_tx_signed  = (^mktemp --suffix .tx     | str trim)

    $pay_skey_json   | save --force $f_pay_skey
    $stake_skey_json | save --force $f_stake_skey
    $stake_vkey_json | save --force $f_stake_vkey

    let pparams    = (^cardano-cli latest query protocol-parameters ...$net_args | from json)
    let deposit    = ($pparams | get stakeAddressDeposit)
    let stake_info = (query-stake-info $acct.stake_address $net_args)
    let utxo       = (largest-lovelace-utxo $acct.delegation_address $net_args)

    ^cardano-cli latest stake-address deregistration-certificate --stake-verification-key-file $f_stake_vkey --key-reg-deposit-amt ($deposit | into string) --out-file $f_dereg_cert

    mut tx_args: list<string> = [
        "--tx-in",            $utxo.txin,
        "--change-address",   $acct.delegation_address,
        "--certificate-file", $f_dereg_cert,
        "--witness-override", "2",
        "--out-file",         $f_tx_body,
    ]
    if $stake_info.rewards > 0 {
        $tx_args = ($tx_args | append ["--withdrawal", $"($acct.stake_address)+($stake_info.rewards)"])
    }
    ^cardano-cli latest transaction build ...($tx_args | append $net_args)

    ^cardano-cli latest transaction sign --tx-body-file $f_tx_body --signing-key-file $f_pay_skey --signing-key-file $f_stake_skey --out-file $f_tx_signed
    ^cardano-cli latest transaction submit --tx-file $f_tx_signed ...$net_args

    let txid = (^cardano-cli latest transaction txid --tx-file $f_tx_signed --output-text | str trim)
    rm --force $f_pay_skey $f_stake_skey $f_stake_vkey $f_dereg_cert $f_tx_body $f_tx_signed
    wait-for-tx $txid $net_args
    $txid
}

# Send all funds (and any pending rewards) from the delegation address to a destination.
def tx-defund [acct: record, dest_address: string, net_args: list<string>, registered: bool, rewards: int] {
    let pay_skey_json = (to-cli-skey $acct.pay_xsk "shelley-payment-key")
    let f_pay_skey  = (^mktemp --suffix .skey   | str trim)
    let f_tx_body   = (^mktemp --suffix .txbody | str trim)
    let f_tx_signed = (^mktemp --suffix .tx     | str trim)
    $pay_skey_json | save --force $f_pay_skey

    let txins = (all-utxo-txins $acct.delegation_address $net_args)
    if ($txins | is-empty) {
        rm --force $f_pay_skey $f_tx_body $f_tx_signed
        error make { msg: "No UTxOs at the delegation address — nothing to defund" }
    }

    mut build_args: list<string> = []
    for txin in $txins {
        $build_args = ($build_args | append ["--tx-in", $txin])
    }
    $build_args = ($build_args | append ["--change-address", $dest_address, "--witness-override", "2", "--out-file", $f_tx_body])

    # Withdraw rewards if registered and rewards > 0
    mut extra_skey_args: list<string> = []
    if $registered and $rewards > 0 {
        let stake_skey_json = (to-cli-skey $acct.stake_xsk "shelley-stake-key")
        let f_stake_skey = (^mktemp --suffix .skey | str trim)
        $stake_skey_json | save --force $f_stake_skey
        $build_args = ($build_args | append ["--withdrawal", $"($acct.stake_address)+($rewards)"])
        $extra_skey_args = ["--signing-key-file", $f_stake_skey]
    }

    ^cardano-cli latest transaction build ...($build_args | append $net_args)
    ^cardano-cli latest transaction sign --tx-body-file $f_tx_body --signing-key-file $f_pay_skey ...$extra_skey_args --out-file $f_tx_signed
    ^cardano-cli latest transaction submit --tx-file $f_tx_signed ...$net_args

    let txid = (^cardano-cli latest transaction txid --tx-file $f_tx_signed --output-text | str trim)
    # Clean up all temp files
    if not ($extra_skey_args | is-empty) {
        rm --force ($extra_skey_args | last)
    }
    rm --force $f_pay_skey $f_tx_body $f_tx_signed
    wait-for-tx $txid $net_args
    $txid
}

# ─── Subcommand implementations ───────────────────────────────────────────────

# Print the funding (delegation) address for a given account index
def do-address [environment: string, index: int] {
    let mnemonic  = (read-mnemonic $environment)
    let acct_skey = (account-skey (root-key $mnemonic))
    let acct      = (derive-account $acct_skey $index)
    print -n $acct.delegation_address
}

# Derive account addresses and write them to the secrets tree (no node needed)
def do-generate [environment: string, num_accounts: int] {
    let mnemonic  = (read-mnemonic $environment)
    let acct_skey = (account-skey (root-key $mnemonic))
    let sroot     = (secrets-root $environment)

    print $"(ansi green)Generating ($num_accounts) account\(s) for ($environment)...(ansi reset)\n"

    for i in 0..<$num_accounts {
        let a   = (derive-account $acct_skey $i)
        let dir = (account-dir $environment $i)
        mkdir $dir
        $a.payment_address    | save --force $"($dir)/payment.addr"
        $a.stake_address      | save --force $"($dir)/stake.addr"
        $a.delegation_address | save --force $"($dir)/delegation.addr"

        print $"  Account #($i)"
        print $"    Payment addr:    ($a.payment_address)"
        print $"    Stake addr:      ($a.stake_address)"
        print $"    Delegation addr: ($a.delegation_address)"
        print ""
    }

    print $"  Addresses written to ($sroot)/<i>/"
    print "  Deposit funds to a Delegation address, then use 'delegate' to activate staking."
}

# Show on-chain delegation status and balances for all accounts
def do-status [environment: string, num_accounts: int] {
    let mnemonic  = (read-mnemonic $environment)
    let acct_skey = (account-skey (root-key $mnemonic))
    let net       = (net-args)

    print $"(ansi green)Querying ($num_accounts) account\(s) on ($environment)...(ansi reset)\n"

    # Single pass: derive keys + query chain for each account
    let acct_data = (0..<$num_accounts | each { |i|
        let a   = (derive-account $acct_skey $i)
        let si  = (try { query-stake-info $a.stake_address $net }
                   catch { { registered: false, delegation: null, rewards: 0 } })
        let bal = (try { query-balance $a.delegation_address $net } catch { 0 })
        { a: $a, si: $si, bal: $bal }
    })

    let rows = ($acct_data | each { |d|
        {
            "Balance":      (lovelace-to-ada $d.bal)
            "Rewards":      (lovelace-to-ada $d.si.rewards)
            "Registered":   $d.si.registered
            "Pool":         ($d.si.delegation | default "--")
            "Stake / Funding Address": $"($d.a.stake_address)\n($d.a.delegation_address)\n"
        }
    })

    print ($rows | table)

    let registered     = ($rows | where Registered == true | length)
    let pool_rows      = ($rows | where Pool != "--")
    let delegated      = ($pool_rows | length)
    let total_lovelace = ($acct_data | each { |d| $d.bal } | math sum)

    print $"  Accounts: ($num_accounts)   Registered: ($registered)   Delegated: ($delegated)   Undelegated: ($num_accounts - $delegated)"
    print $"  Total balance: (lovelace-to-ada $total_lovelace)"

    if not ($pool_rows | is-empty) {
        print "\n  Pool breakdown:"
        $pool_rows | group-by Pool | transpose pool accounts | each { |row|
            print $"    ($row.pool): ($row.accounts | length) account\(s)"
        } | ignore
    }
}

# Register and delegate an account's stake to a pool
def do-delegate [environment: string, index: int, pool_id, dry_run: bool] {
    if $pool_id == null {
        error make { msg: "Must provide --pool-id (-p)" }
    }

    let mnemonic  = (read-mnemonic $environment)
    let net       = (net-args)
    let acct_skey = (account-skey (root-key $mnemonic))
    let acct      = (derive-account $acct_skey $index)
    let si        = (query-stake-info $acct.stake_address $net)
    let balance   = (query-balance $acct.delegation_address $net)

    let cur_status = if $si.registered {
        $"delegating to ($si.delegation | default 'unknown')"
    } else {
        "not registered"
    }

    print $"\n  Account #($index) on ($environment)"
    print $"  Delegation address: ($acct.delegation_address)"
    print $"  Stake address:      ($acct.stake_address)"
    print $"  Balance:            (lovelace-to-ada $balance)"
    print $"  Current status:     ($cur_status)"
    print $"  Target pool:        ($pool_id)\n"

    if $dry_run {
        print "(ansi yellow)Dry run -- no transaction submitted.(ansi reset)"
        return
    }

    # Minimum: 2 ADA registration deposit + fees; or ~0.5 ADA fees if already registered
    let min_balance = if $si.registered { 500_000 } else { 2_500_000 }
    if $balance < $min_balance {
        error make { msg: $"Insufficient balance: (lovelace-to-ada $balance). Need at least (lovelace-to-ada $min_balance)." }
    }

    print "Building and submitting delegation transaction..."
    let txid = (tx-delegate $acct $pool_id $net $si.registered)
    print $"(ansi green)Success! TxID: ($txid)(ansi reset)"
}

# Remove pool delegation but keep stake key registered
def do-dedelegate [environment: string, index: int, dry_run: bool] {
    let mnemonic  = (read-mnemonic $environment)
    let net       = (net-args)
    let acct_skey = (account-skey (root-key $mnemonic))
    let acct      = (derive-account $acct_skey $index)
    let si        = (query-stake-info $acct.stake_address $net)

    if not $si.registered {
        print $"(ansi yellow)Account #($index) is not registered -- nothing to dedelegate.(ansi reset)"
        return
    }

    if $si.delegation == null {
        print $"(ansi yellow)Account #($index) is not delegated to any pool.(ansi reset)"
        return
    }

    let balance  = (query-balance $acct.delegation_address $net)
    let cur_pool = ($si.delegation | default "none")

    print $"\n  Account #($index) on ($environment)"
    print $"  Delegation address:      ($acct.delegation_address)"
    print $"  Balance:                 (lovelace-to-ada $balance)"
    print $"  Currently delegating to: ($cur_pool)"
    print $"  Pending rewards:         (lovelace-to-ada $si.rewards)"
    print "  Action:                  Remove pool delegation (stake key stays registered)\n"

    if $dry_run {
        print "(ansi yellow)Dry run -- no transaction submitted.(ansi reset)"
        return
    }

    print "Building and submitting de-delegation transaction..."
    let txid = (tx-dedelegate $acct $net)
    print $"(ansi green)Success! TxID: ($txid)(ansi reset)"
    print "Stake key remains registered. Any pending rewards were withdrawn."
}

# Deregister stake key, withdraw pending rewards, and reclaim 2 ADA deposit
def do-deregister [environment: string, index: int, dry_run: bool] {
    let mnemonic  = (read-mnemonic $environment)
    let net       = (net-args)
    let acct_skey = (account-skey (root-key $mnemonic))
    let acct      = (derive-account $acct_skey $index)
    let si        = (query-stake-info $acct.stake_address $net)

    if not $si.registered {
        print $"(ansi yellow)Account #($index) is not registered -- nothing to deregister.(ansi reset)"
        return
    }

    let balance  = (query-balance $acct.delegation_address $net)
    let cur_pool = ($si.delegation | default "none")

    print $"\n  Account #($index) on ($environment)"
    print $"  Delegation address:      ($acct.delegation_address)"
    print $"  Balance:                 (lovelace-to-ada $balance)"
    print $"  Currently delegating to: ($cur_pool)"
    print $"  Pending rewards:         (lovelace-to-ada $si.rewards)"
    print "  Action:                  Deregister stake key + reclaim 2 ADA deposit\n"

    if $dry_run {
        print "(ansi yellow)Dry run -- no transaction submitted.(ansi reset)"
        return
    }

    print "Building and submitting deregistration transaction..."
    let txid = (tx-deregister $acct $net)
    print $"(ansi green)Success! TxID: ($txid)(ansi reset)"
    print "Deposit (2 ADA) and any pending rewards returned to your delegation address."
}

# Send all funds (and rewards if registered) to a destination address
def do-defund [environment: string, index: int, dest_address, dry_run: bool] {
    if $dest_address == null {
        error make { msg: "Must provide --dest-address (-d)" }
    }

    let mnemonic  = (read-mnemonic $environment)
    let net       = (net-args)
    let acct_skey = (account-skey (root-key $mnemonic))
    let acct      = (derive-account $acct_skey $index)
    let si        = (try { query-stake-info $acct.stake_address $net }
                     catch { { registered: false, delegation: null, rewards: 0 } })
    let balance   = (query-balance $acct.delegation_address $net)

    if $balance == 0 and $si.rewards == 0 {
        print $"(ansi yellow)Account #($index) has no funds or rewards to defund.(ansi reset)"
        return
    }

    print $"\n  Account #($index) on ($environment)"
    print $"  Delegation address: ($acct.delegation_address)"
    print $"  Balance:            (lovelace-to-ada $balance)"
    print $"  Rewards:            (lovelace-to-ada $si.rewards)"
    print $"  Registered:         ($si.registered)"
    print $"  Destination:        ($dest_address)\n"

    if $dry_run {
        print "(ansi yellow)Dry run -- no transaction submitted.(ansi reset)"
        return
    }

    print "Building and submitting defund transaction..."
    let txid = (tx-defund $acct $dest_address $net $si.registered $si.rewards)
    print $"(ansi green)Success! TxID: ($txid)(ansi reset)"
    print $"All funds sent to ($dest_address)."
    if $si.registered {
        print "Note: Stake key is still registered. Use 'deregister' to reclaim the 2 ADA deposit."
    }
}

# ─── Help & Dispatcher ────────────────────────────────────────────────────────

def show-help [] {
    print r#'
Cardano Pool Delegation Manager
================================

Derives Shelley wallet accounts from a BIP39 mnemonic and manages
their stake pool delegations on testnet (preview / preprod).

USAGE  (run from repo root, inside the playground devShell)
  pool-delegations.nu [env] generate   [-n N]
  pool-delegations.nu [env] status     [-n N]
  pool-delegations.nu [env] address     -i I
  pool-delegations.nu [env] delegate   -p <pool1...> -i I [--dry-run]
  pool-delegations.nu [env] dedelegate -i I [--dry-run]
  pool-delegations.nu [env] deregister -i I [--dry-run]
  pool-delegations.nu [env] defund     -d <addr> -i I [--dry-run]

SUBCOMMANDS
  generate    Derive account addresses and write them to the secrets tree
  status      Show on-chain balances, rewards, and delegation state
  address     Print the funding (delegation) address for a given account index
  delegate    Register stake key (if needed) and delegate to a pool
  dedelegate  Remove pool delegation; stake key stays registered (no deposit change)
  deregister  Deregister stake key; withdraws rewards + reclaims 2 ADA deposit
  defund      Send all funds (and rewards) to a destination address

ARGUMENTS
  [env]              Playground environment: "preview", "preprod", etc.
                     Optional -- falls back to the $ENV environment variable if omitted.
                     Mnemonic is read from secrets/envs/<env>/pool-delegations/pool-delegations.mnemonic

OPTIONS
  -n, --num-accounts   Accounts to derive (generate default: 3) / inspect (status default: count of existing account dirs)
  -i, --index          Account index (required for delegate, dedelegate, deregister, defund)
  -p, --pool-id        Stake pool ID in bech32 (pool1...) or hex form
  -d, --dest-address   Destination address for defund
  --dry-run            Print details but do not submit any transaction

ENVIRONMENT VARIABLES (set automatically by the devShell)
  ENV                      Default environment when <env> arg is omitted
  TESTNET_MAGIC            Used for all cardano-cli network arguments
  CARDANO_NODE_SOCKET_PATH Required for status, delegate, and undelegate
  CARDANO_NODE_NETWORK_ID  Available; mirrors TESTNET_MAGIC

SECRETS LAYOUT
  secrets/envs/<env>/pool-delegations/
    pool-delegations.mnemonic       24-word BIP39 mnemonic (plaintext for now)
    <i>/
      payment.addr                  Written by generate; payment-only address
      stake.addr                    Written by generate; stake address
      delegation.addr               Written by generate; fund this address!

WORKFLOW
  1. Create mnemonic:
       mkdir -p secrets/envs/preview/pool-delegations
       echo "word1 word2 ... word24" | save secrets/envs/preview/pool-delegations/pool-delegations.mnemonic

  2. generate   -> derive and save account addresses to secrets/envs/<env>/pool-delegations/<i>/
  3. Fund       -> send ADA to each delegation address (from faucet / wallet)
  4. status     -> confirm balances arrived on-chain
  5. delegate   -> register + delegate each account to chosen pools
  6. status     -> verify delegation is active
  7. dedelegate -> remove pool delegation (stake key stays registered)
  8. deregister -> when done, deregister stake key + reclaim 2 ADA deposit

EXAMPLES  (with $ENV=preview set in the devShell)
  pool-delegations.nu generate              # uses $ENV
  pool-delegations.nu preview generate -n 10
  pool-delegations.nu status
  pool-delegations.nu preview status
  pool-delegations.nu address -i 0               # prints funding address to stdout
  pool-delegations.nu delegate   -p pool1abc... -i 0
  pool-delegations.nu preview delegate   -p pool1abc... --dry-run
  pool-delegations.nu dedelegate -i 2
  pool-delegations.nu preview dedelegate -i 2 --dry-run
  pool-delegations.nu deregister -i 0
  pool-delegations.nu preview deregister -i 0 --dry-run
  pool-delegations.nu defund -d addr_test1qz... -i 0
  pool-delegations.nu preview defund -d addr_test1qz... -i 0 --dry-run

NOTES
  - Each account is self-funded: its own payment key (from the mnemonic)
    signs delegation transactions. No separate faucet key is required.
  - Registration deposit: 2 ADA (refunded on deregistration).
  - Private key material is written only to short-lived mktemp files
    deleted immediately after use.
  - TODO: integrate sops encryption for all files under the secrets tree.
'#
}

# Cardano Pool Delegation Manager
def main [
    environment?: string          # Playground environment, e.g. "preview"; falls back to $ENV
    subcommand?: string           # generate | status | address | delegate | dedelegate | deregister | defund
    --num-accounts (-n): int       # Accounts: generate defaults to 3, status defaults to existing count
    --index (-i): int              # Account index (delegate, dedelegate, deregister, defund)
    --pool-id (-p): string        # Pool ID in bech32 or hex (delegate)
    --dest-address (-d): string   # Destination address (defund)
    --dry-run                     # Show details without submitting
] {
    let known = ["generate", "status", "address", "delegate", "dedelegate", "deregister", "defund"]

    # No args at all → help
    if ($environment == null) and ($subcommand == null) {
        show-help
        return
    }

    # If only one positional was given and it looks like a subcommand name,
    # treat it as the subcommand and resolve the environment from $ENV.
    let subcmd_in_env_slot = ($subcommand == null) and ($environment != null) and ($environment in $known)

    let resolved_env = if $subcmd_in_env_slot {
        # env slot holds a subcommand name; fall back to $ENV for the environment
        if "ENV" not-in $env {
            error make { msg: "Provide an <environment> argument (e.g. \"preview\") or set the ENV environment variable" }
        }
        $env.ENV
    } else {
        resolve-env $environment
    }
    let resolved_cmd = if $subcmd_in_env_slot { $environment } else { $subcommand }

    check-network $resolved_env

    match $resolved_cmd {
        null         => { show-help }
        "generate"   => { do-generate   $resolved_env ($num_accounts | default 3) }
        "status"     => {
            let n = if $num_accounts != null { $num_accounts } else {
                let found = (count-accounts $resolved_env)
                if $found == 0 {
                    error make { msg: $"No account directories found under (secrets-root $resolved_env)/. Run 'generate' first or pass -n." }
                }
                $found
            }
            do-status $resolved_env $n
        }
        "address"    => {
            if $index == null { error make { msg: "Must provide --index (-i) for address" } }
            do-address $resolved_env $index
        }
        "delegate"   => {
            if $index == null { error make { msg: "Must provide --index (-i) for delegate" } }
            do-delegate $resolved_env $index $pool_id $dry_run
        }
        "dedelegate" => {
            if $index == null { error make { msg: "Must provide --index (-i) for dedelegate" } }
            do-dedelegate $resolved_env $index $dry_run
        }
        "deregister" => {
            if $index == null { error make { msg: "Must provide --index (-i) for deregister" } }
            do-deregister $resolved_env $index $dry_run
        }
        "defund"     => {
            if $index == null { error make { msg: "Must provide --index (-i) for defund" } }
            do-defund $resolved_env $index $dest_address $dry_run
        }
        _            => {
            print $"(ansi red)Unknown subcommand: ($resolved_cmd)(ansi reset)"
            print "Valid subcommands: generate, status, address, delegate, dedelegate, deregister, defund"
        }
    }
}
