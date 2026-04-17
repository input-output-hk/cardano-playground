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
#   pool-delegations.nu [env] generate-mnemonic
#   pool-delegations.nu [env] generate-accounts [-n N]
#   pool-delegations.nu [env] status            [-n N] [--dbsync HOST]
#   pool-delegations.nu [env] address            -i I
#   pool-delegations.nu [env] delegate           -p <pool1...> -i I [--dry-run] [--confirm]
#   pool-delegations.nu [env] dedelegate         -i I [--dry-run] [--confirm]
#   pool-delegations.nu [env] deregister         -i I [--dry-run] [--confirm]
#   pool-delegations.nu [env] defund             -d <addr> -i I [--dry-run] [--confirm]

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
        error make --unspanned { msg: "Provide an <environment> argument (e.g. \"preview\") or set the ENV environment variable" }
    }
}

# Read and validate the mnemonic for the given environment
def read-mnemonic [environment: string] {
    let path = (mnemonic-path $environment)
    if not ($path | path exists) {
        error make --unspanned { msg: $"Mnemonic not found: ($path)\n  Create it with:\n    mkdir -p (secrets-root $environment)\n    echo '<24 words>' | save ($path)\n    just sops-encrypt-binary ($path)" }
    }
    sops-decrypt $path | str trim
}

# ─── SOPS helpers ─────────────────────────────────────────────────────────────

# Find the .sops.yaml config by walking up from a file's parent directory
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

# Decrypt a sops-encrypted file and return its plaintext content
def sops-decrypt [file: string] {
    let config = (sops-config $file)
    ^sops --config $config --input-type binary --output-type binary --decrypt $file
}

# Encrypt content and save to file using sops.
# Writes plaintext to the target path first so sops can match .sops.yaml creation
# rules against the real path, then replaces it with the encrypted output.
def sops-encrypt [content: string, file: string] {
    let config = (sops-config $file)
    $content | save --force $file
    try {
        let encrypted = (^sops --config $config --input-type binary --output-type binary --encrypt $file)
        $encrypted | save --force $file
    } catch {
        rm --force $file
        error make --unspanned { msg: $"Failed to sops-encrypt ($file). Check .sops.yaml creation rules." }
    }
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

# Format a single relay entry from pool-state JSON
def format-relay [relay: record] {
    if ("single host address" in ($relay | columns)) {
        let addr = ($relay | get "single host address")
        let host = ($addr | get -o IPv4 | default ($addr | get -o IPv6 | default "?"))
        let port = ($addr | get -o port | default "?")
        $"($host):($port)"
    } else if ("single host name" in ($relay | columns)) {
        let r = ($relay | get "single host name")
        let host = ($r | get -o dnsName | default ($r | get -o hostname | default "?"))
        let port = ($r | get -o port | default "?")
        $"($host):($port)"
    } else {
        ($relay | columns | first | default "unknown relay")
    }
}

# Query dbsync via ssh for each pool's last forged block.
# SCPs the SQL to the remote host to avoid quoting issues across shell layers.
# Returns a list of {pool_id, time, slot, block} records.
def query-last-forged [pool_ids: list<string>, dbsync_host: string] {
    let id_list = ($pool_ids | each { |id| $"'($id)'" } | str join ', ')
    let sql = $"SELECT DISTINCT ON \(ph.view\) ph.view AS pool_id, b.time::text AS last_time, b.slot_no AS last_slot, b.block_no AS last_block FROM block b JOIN slot_leader sl ON b.slot_leader_id = sl.id JOIN pool_hash ph ON sl.pool_hash_id = ph.id WHERE ph.view IN \(($id_list)\) ORDER BY ph.view, b.block_no DESC"
    let tmp = (^mktemp --suffix .sql | str trim)
    $sql | save --force $tmp
    ^just scp $tmp $"($dbsync_host):/tmp/pool-last-forged.sql"
    rm --force $tmp
    let raw = (^just ssh $dbsync_host "'psql -P pager=off -t -A -X -F , -U cexplorer cexplorer < /tmp/pool-last-forged.sql'" | str trim)
    if ($raw | is-empty) { return [] }
    $raw | lines | where { |l| ($l | str trim) != "" } | each { |line|
        let parts = ($line | split column ',' pool_id time slot block | first)
        {
            pool_id: ($parts.pool_id | str trim)
            time: ($parts.time | str trim)
            slot: ($parts.slot | str trim)
            block: ($parts.block | str trim)
        }
    }
}

# Build a multi-line string with pool ID and details for the Pool table cell
def format-pool-cell [pool_id: string, info: record, last_forged?: record] {
    mut lines: list<string> = [$pool_id]

    # Off-chain metadata (ticker, name)
    if $info.ticker != null or $info.name != null {
        mut parts: list<string> = []
        if $info.ticker != null { $parts = ($parts | append $info.ticker) }
        if $info.name != null { $parts = ($parts | append $info.name) }
        $lines = ($lines | append ($parts | str join ' | '))
    } else if $info.meta_url != null {
        $lines = ($lines | append '(metadata unavailable)')
    } else {
        $lines = ($lines | append '(no metadata registered)')
    }

    # Relays
    if not ($info.relays | is-empty) {
        let relay_strs = ($info.relays | each { |r| format-relay $r })
        $lines = ($lines | append ($relay_strs | str join ', '))
    }

    # On-chain parameters
    mut params: list<string> = []
    if $info.margin != null { $params = ($params | append $"Margin: ($info.margin)%") }
    if $info.pledge != null { $params = ($params | append $"Pledge: (lovelace-to-ada $info.pledge)") }
    if not ($params | is-empty) {
        $lines = ($lines | append ($params | str join ' | '))
    }

    if $info.homepage != null { $lines = ($lines | append $info.homepage) }
    if $info.retiring != null { $lines = ($lines | append $"Retiring: epoch ($info.retiring)") }

    # Last forged block from dbsync (when available)
    if $last_forged != null {
        $lines = ($lines | append $"Last block: ($last_forged.block) slot ($last_forged.slot) \(($last_forged.time)\)")
    }

    $lines | str join "\n"
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
            error make --unspanned { msg: $"($var) is ($env | get $var) but expected ($expected) for ($environment)" }
        }
    }
}

# Always testnet -- reads TESTNET_MAGIC from the devShell environment.
def net-args [] {
    if ("TESTNET_MAGIC" not-in $env) {
        error make --unspanned { msg: "TESTNET_MAGIC is not set. Are you inside the playground devShell?" }
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
        error make --unspanned { msg: $"No lovelace-only UTxO found at ($address)" }
    }
    $utxos | first
}

# Returns all UTxO txins at an address as a list of strings
def all-utxo-txins [address: string, net_args: list<string>] {
    let data = (^cardano-cli latest query utxo --address $address --output-json ...$net_args | from json)
    if ($data | is-empty) { return [] }
    $data | transpose key value | each { |row| $row.key }
}

# Query on-chain pool parameters and fetch off-chain metadata.
# Returns a record with relays, margin, cost, pledge, ticker, name, etc., or null.
def query-pool-info [pool_id: string, net_args: list<string>] {
    let state = (^cardano-cli latest query pool-state --stake-pool-id $pool_id ...$net_args | from json)
    let entries = ($state | transpose k v)
    if ($entries | is-empty) { return null }
    let pstate = ($entries | first | get v)
    let params = ($pstate | get -o poolParams)
    if $params == null { return null }

    # Support both sps-prefixed (newer cardano-cli) and unprefixed field names
    let relays = ($params | get -o spsRelays | default ($params | get -o relays | default []))
    let margin_raw = ($params | get -o spsMargin | default ($params | get -o margin))
    let margin = if $margin_raw != null {
        if ($margin_raw | describe | str starts-with 'record') {
            let num = ($margin_raw | get -o numerator | default 0)
            let den = ($margin_raw | get -o denominator | default 1)
            if $den != 0 { (($num | into float) / $den * 100) | math round --precision 2 } else { null }
        } else {
            (($margin_raw | into float) * 100) | math round --precision 2
        }
    } else { null }
    let cost = ($params | get -o spsCost | default ($params | get -o cost))
    let pledge = ($params | get -o spsPledge | default ($params | get -o pledge))

    let meta_section = ($params | get -o spsMetadata | default ($params | get -o metadata))
    let meta_url = if $meta_section != null { $meta_section | get -o url } else { null }
    let meta = if $meta_url != null {
        try { ^curl -fkLs $meta_url | from json } catch { null }
    } else { null }

    let retiring_raw = ($pstate | get -o retiring)
    let retiring = if $retiring_raw != null {
        if ($retiring_raw | describe | str starts-with 'record') {
            $retiring_raw | get -o epoch
        } else {
            $retiring_raw
        }
    } else { null }

    {
        ticker: (if $meta != null { $meta | get -o ticker } else { null })
        name: (if $meta != null { $meta | get -o name } else { null })
        homepage: (if $meta != null { $meta | get -o homepage } else { null })
        relays: $relays
        margin: $margin
        cost: $cost
        pledge: $pledge
        meta_url: $meta_url
        retiring: $retiring
    }
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

# Show signed transaction, prompt for confirmation, and submit.
# Returns txid on success, or null if the user declines.
def confirm-and-submit [tx_file: string, net_args: list<string>, confirm: bool] {
    if $confirm {
        print "\n  Transaction view:"
        print (^cardano-cli debug transaction view --tx-file $tx_file --output-json)
        print ""
        let response = (input "  Submit this transaction? [y/N] ")
        if ($response | str downcase | str trim) != "y" {
            print $"(ansi yellow)Transaction cancelled.(ansi reset)"
            return null
        }
    }
    ^cardano-cli latest transaction submit --tx-file $tx_file ...$net_args
    ^cardano-cli latest transaction txid --tx-file $tx_file --output-text | str trim
}

# ─── Transactions ─────────────────────────────────────────────────────────────

# Register stake key (if needed) and delegate to pool.
# Signs with both the payment key and stake key derived from the account mnemonic.
def tx-delegate [
    acct: record
    pool_id: string
    net_args: list<string>
    registered: bool          # true = already on-chain, skip registration cert
    confirm: bool
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
    let txid = (confirm-and-submit $f_tx_signed $net_args $confirm)
    rm --force $f_pay_skey $f_stake_skey $f_stake_vkey $f_reg_cert $f_deleg_cert $f_tx_body $f_tx_signed
    if $txid == null { return null }
    wait-for-tx $txid $net_args
    $txid
}

# Remove pool delegation but keep the stake key registered.
# Submits deregistration + re-registration in one tx (net zero deposit).
def tx-dedelegate [acct: record, net_args: list<string>, confirm: bool] {
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
    let txid = (confirm-and-submit $f_tx_signed $net_args $confirm)
    rm --force $f_pay_skey $f_stake_skey $f_stake_vkey $f_dereg_cert $f_reg_cert $f_tx_body $f_tx_signed
    if $txid == null { return null }
    wait-for-tx $txid $net_args
    $txid
}

# Deregister stake key, withdraw pending rewards, reclaim 2 ADA deposit.
def tx-deregister [acct: record, net_args: list<string>, confirm: bool] {
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
    let txid = (confirm-and-submit $f_tx_signed $net_args $confirm)
    rm --force $f_pay_skey $f_stake_skey $f_stake_vkey $f_dereg_cert $f_tx_body $f_tx_signed
    if $txid == null { return null }
    wait-for-tx $txid $net_args
    $txid
}

# Send all funds (and any pending rewards) from the delegation address to a destination.
def tx-defund [acct: record, dest_address: string, net_args: list<string>, registered: bool, rewards: int, confirm: bool] {
    let pay_skey_json = (to-cli-skey $acct.pay_xsk "shelley-payment-key")
    let f_pay_skey  = (^mktemp --suffix .skey   | str trim)
    let f_tx_body   = (^mktemp --suffix .txbody | str trim)
    let f_tx_signed = (^mktemp --suffix .tx     | str trim)
    $pay_skey_json | save --force $f_pay_skey

    let txins = (all-utxo-txins $acct.delegation_address $net_args)
    if ($txins | is-empty) {
        rm --force $f_pay_skey $f_tx_body $f_tx_signed
        error make --unspanned { msg: "No UTxOs at the delegation address — nothing to defund" }
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
    let txid = (confirm-and-submit $f_tx_signed $net_args $confirm)
    # Clean up all temp files
    if not ($extra_skey_args | is-empty) {
        rm --force ($extra_skey_args | last)
    }
    rm --force $f_pay_skey $f_tx_body $f_tx_signed
    if $txid == null { return null }
    wait-for-tx $txid $net_args
    $txid
}

# ─── Subcommand implementations ───────────────────────────────────────────────

# Generate a new BIP39 mnemonic and save it sops-encrypted (skip if one exists)
def do-generate-mnemonic [environment: string] {
    let path = (mnemonic-path $environment)
    if ($path | path exists) {
        print $"(ansi yellow)Mnemonic already exists at ($path) — skipping.(ansi reset)"
        return
    }
    let sroot = (secrets-root $environment)
    mkdir $sroot
    let mnemonic = (^cardano-address recovery-phrase generate | str trim)
    sops-encrypt $mnemonic $path
    print $"(ansi green)Mnemonic generated and encrypted at ($path)(ansi reset)"
}

# Print the funding (delegation) address for a given account index
def do-address [environment: string, index: int] {
    let mnemonic  = (read-mnemonic $environment)
    let acct_skey = (account-skey (root-key $mnemonic))
    let acct      = (derive-account $acct_skey $index)
    print -n $acct.delegation_address
}

# Derive account addresses and write them to the secrets tree (no node needed)
def do-generate-accounts [environment: string, num_accounts: int] {
    let mnemonic  = (read-mnemonic $environment)
    let acct_skey = (account-skey (root-key $mnemonic))
    let sroot     = (secrets-root $environment)

    print $"(ansi green)Generating ($num_accounts) account\(s) for ($environment)...(ansi reset)\n"

    for i in 0..<$num_accounts {
        let dir = (account-dir $environment $i)
        if ($dir | path exists) {
            print $"  Account #($i) — already exists, skipping"
            continue
        }
        let a = (derive-account $acct_skey $i)
        mkdir $dir
        sops-encrypt $a.payment_address $"($dir)/payment.addr"
        sops-encrypt $a.stake_address $"($dir)/stake.addr"
        sops-encrypt $a.delegation_address $"($dir)/delegation.addr"

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
def do-status [environment: string, num_accounts: int, dbsync_host?: string] {
    let mnemonic  = (read-mnemonic $environment)
    let acct_skey = (account-skey (root-key $mnemonic))
    let net       = (net-args)

    print $"(ansi green)Querying ($num_accounts) account\(s) on ($environment)...(ansi reset)\n"

    # Single pass: derive keys + query chain for each account
    let acct_data = (0..<$num_accounts | each { |i|
        print -n $"  Account ($i)/($num_accounts)...\r"
        let a   = (derive-account $acct_skey $i)
        let si  = (try { query-stake-info $a.stake_address $net }
                   catch { { registered: false, delegation: null, rewards: 0 } })
        let bal = (try { query-balance $a.delegation_address $net } catch { 0 })
        { a: $a, si: $si, bal: $bal }
    })
    print $"  Queried ($num_accounts) account\(s)                "

    # Fetch info for each unique delegated pool (one query per pool)
    let pool_ids = ($acct_data
        | where { |d| $d.si.delegation != null }
        | each { |d| $d.si.delegation }
        | uniq)
    let pool_count = ($pool_ids | length)
    let pool_infos = ($pool_ids | enumerate | each { |e|
        print -n $"  Pool ($e.index + 1)/($pool_count)...\r"
        let info = (try { query-pool-info $e.item $net } catch { null })
        { pool_id: $e.item, info: $info }
    })
    if $pool_count > 0 {
        print $"  Fetched ($pool_count) pool\(s) info              "
    }

    # Optionally query dbsync for last forged block per pool
    let forged_data = if $dbsync_host != null and not ($pool_ids | is-empty) {
        print $"\n(ansi green)Querying dbsync on ($dbsync_host) for last forged blocks...(ansi reset)"
        let result = (try { query-last-forged $pool_ids $dbsync_host } catch { [] })
        print ""
        $result
    } else { [] }

    let rows = ($acct_data | each { |d|
        let pool_cell = if $d.si.delegation != null {
            let pid = $d.si.delegation
            let matches = ($pool_infos | where pool_id == $pid)
            let forged_match = ($forged_data | where pool_id == $pid)
            let last_forged = if not ($forged_match | is-empty) { $forged_match | first } else { null }
            if not ($matches | is-empty) and ($matches | first | get info) != null {
                format-pool-cell $pid ($matches | first | get info) $last_forged
            } else if $last_forged != null {
                format-pool-cell $pid { ticker: null, name: null, homepage: null, relays: [], margin: null, pledge: null, meta_url: null, retiring: null } $last_forged
            } else {
                $pid
            }
        } else { "--" }
        {
            "Balance":      (lovelace-to-ada $d.bal)
            "Rewards":      (lovelace-to-ada $d.si.rewards)
            "Reg":          $d.si.registered
            "Pool":         $"($pool_cell)\n"
            "Stake / Funding Address": $"($d.a.stake_address)\n($d.a.delegation_address)\n"
        }
    })

    print ($rows | table)

    let registered     = ($acct_data | where { |d| $d.si.registered } | length)
    let delegated_data = ($acct_data | where { |d| $d.si.delegation != null })
    let delegated      = ($delegated_data | length)
    let total_lovelace     = ($acct_data | each { |d| $d.bal } | math sum)
    let delegated_lovelace = ($delegated_data | each { |d| $d.bal } | math sum | default 0)

    print $"  Accounts: ($num_accounts)   Registered: ($registered)   Delegated: ($delegated)   Undelegated: ($num_accounts - $delegated)"
    print $"  Total balance: (lovelace-to-ada $total_lovelace)   Delegated balance: (lovelace-to-ada $delegated_lovelace)"

    if not ($delegated_data | is-empty) {
        print "\n  Pool breakdown:"
        $delegated_data | each { |d| $d.si.delegation } | uniq | each { |pid|
            let count = ($delegated_data | where { |d| $d.si.delegation == $pid } | length)
            let ticker_match = ($pool_infos | where pool_id == $pid)
            let ticker = if not ($ticker_match | is-empty) and ($ticker_match | first | get info) != null {
                $ticker_match | first | get info | get -o ticker
            } else { null }
            let label = if $ticker != null {
                [$pid, " \(", $ticker, "\)"] | str join
            } else { $pid }
            print $"    ($label): ($count) account\(s)"
        } | ignore
    }
}

# Register and delegate an account's stake to a pool
def do-delegate [environment: string, index: int, pool_id, dry_run: bool, confirm: bool] {
    if $pool_id == null {
        error make --unspanned { msg: "Must provide --pool-id (-p)" }
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
        print $"(ansi yellow)Dry run -- no transaction submitted.(ansi reset)"
        return
    }

    # Minimum: 2 ADA registration deposit + fees; or ~0.5 ADA fees if already registered
    let min_balance = if $si.registered { 500_000 } else { 2_500_000 }
    if $balance < $min_balance {
        error make --unspanned { msg: $"Insufficient balance: (lovelace-to-ada $balance). Need at least (lovelace-to-ada $min_balance)." }
    }

    print "Building delegation transaction..."
    let txid = (tx-delegate $acct $pool_id $net $si.registered $confirm)
    if $txid == null { return }
    print $"(ansi green)Success! TxID: ($txid)(ansi reset)"
}

# Remove pool delegation but keep stake key registered
def do-dedelegate [environment: string, index: int, dry_run: bool, confirm: bool] {
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
        print $"(ansi yellow)Dry run -- no transaction submitted.(ansi reset)"
        return
    }

    print "Building de-delegation transaction..."
    let txid = (tx-dedelegate $acct $net $confirm)
    if $txid == null { return }
    print $"(ansi green)Success! TxID: ($txid)(ansi reset)"
    print "Stake key remains registered. Any pending rewards were withdrawn."
}

# Deregister stake key, withdraw pending rewards, and reclaim 2 ADA deposit
def do-deregister [environment: string, index: int, dry_run: bool, confirm: bool] {
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
        print $"(ansi yellow)Dry run -- no transaction submitted.(ansi reset)"
        return
    }

    print "Building deregistration transaction..."
    let txid = (tx-deregister $acct $net $confirm)
    if $txid == null { return }
    print $"(ansi green)Success! TxID: ($txid)(ansi reset)"
    print "Deposit (2 ADA) and any pending rewards returned to your delegation address."
}

# Send all funds (and rewards if registered) to a destination address
def do-defund [environment: string, index: int, dest_address, dry_run: bool, confirm: bool] {
    if $dest_address == null {
        error make --unspanned { msg: "Must provide --dest-address (-d)" }
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
        print $"(ansi yellow)Dry run -- no transaction submitted.(ansi reset)"
        return
    }

    print "Building defund transaction..."
    let txid = (tx-defund $acct $dest_address $net $si.registered $si.rewards $confirm)
    if $txid == null { return }
    print $"(ansi green)Success! TxID: ($txid)(ansi reset)"
    print $"All funds sent to ($dest_address)."
    if $si.registered {
        print "Note: Stake key is still registered. Use 'deregister' to reclaim the 2 ADA deposit."
    }
}

# ─── Help & Dispatcher ────────────────────────────────────────────────────────

def show-help [] {
    let h = (ansi green_bold)        # section headers
    let c = (ansi cyan)              # commands / subcommands
    let f = (ansi yellow)            # flags and options
    let d = (ansi white_dimmed)      # descriptions / dim text
    let p = (ansi cyan_dimmed)       # paths
    let n = (ansi default)           # step numbers
    let r = (ansi reset)

    print $"
  ($h)Cardano Pool Delegation Manager($r)

  Derives Shelley wallet accounts from a BIP39 mnemonic and manages
  their stake pool delegations on testnet \(preview / preprod\).

  ($h)Usage($r)  \(run from repo root, inside the playground devShell\)

    ($c)pool-delegations.nu($r) [env] ($c)generate-mnemonic($r)
    ($c)pool-delegations.nu($r) [env] ($c)generate-accounts($r) [($f)-n($r) N]
    ($c)pool-delegations.nu($r) [env] ($c)status($r)     [($f)-n($r) N] [($f)--dbsync($r) HOST]
    ($c)pool-delegations.nu($r) [env] ($c)address($r)     ($f)-i($r) I
    ($c)pool-delegations.nu($r) [env] ($c)delegate($r)   ($f)-p($r) <pool1...> ($f)-i($r) I [($f)--dry-run($r)] [($f)--confirm($r)]
    ($c)pool-delegations.nu($r) [env] ($c)dedelegate($r) ($f)-i($r) I [($f)--dry-run($r)] [($f)--confirm($r)]
    ($c)pool-delegations.nu($r) [env] ($c)deregister($r) ($f)-i($r) I [($f)--dry-run($r)] [($f)--confirm($r)]
    ($c)pool-delegations.nu($r) [env] ($c)defund($r)     ($f)-d($r) <addr> ($f)-i($r) I [($f)--dry-run($r)] [($f)--confirm($r)]

  ($h)Subcommands($r)

    ($c)generate-mnemonic($r)  Create a new BIP39 mnemonic and save it sops-encrypted \(skips if exists\)
    ($c)generate-accounts($r)  Derive account addresses and write them to the secrets tree
    ($c)status($r)      Show on-chain balances, rewards, and delegation state
    ($c)address($r)     Print the funding \(delegation\) address for a given account index
    ($c)delegate($r)    Register stake key \(if needed\) and delegate to a pool
    ($c)dedelegate($r)  Remove pool delegation; stake key stays registered \(no deposit change\)
    ($c)deregister($r)  Deregister stake key; withdraws rewards + reclaims 2 ADA deposit
    ($c)defund($r)      Send all funds \(and rewards\) to a destination address

  ($h)Arguments($r)

    [env]              Playground environment: ($c)preview($r), ($c)preprod($r), etc.
                       Optional — falls back to ($f)$ENV($r) if omitted.
                       Mnemonic read from ($p)secrets/envs/<env>/pool-delegations/pool-delegations.mnemonic($r)

  ($h)Options($r)

    ($f)-n($r), ($f)--num-accounts($r)   Accounts to derive \(generate-accounts default: 3\) / inspect \(status default: existing count\)
    ($f)-i($r), ($f)--index($r)          Account index \(required for delegate, dedelegate, deregister, defund\)
    ($f)-p($r), ($f)--pool-id($r)        Stake pool ID in bech32 \(pool1...\) or hex form
    ($f)-d($r), ($f)--dest-address($r)   Destination address for defund
    ($f)--dry-run($r)            Print details but do not submit any transaction
    ($f)--confirm($r)            Review transaction JSON before submitting \(prompts y/N\)
    ($f)--dbsync($r) HOST        SSH hostname of dbsync instance; adds last-forged-block to status

  ($h)Environment Variables($r) ($d)\(set automatically by the devShell\)($r)

    ($f)ENV($r)                      Default environment when [env] arg is omitted
    ($f)TESTNET_MAGIC($r)            Used for all cardano-cli network arguments
    ($f)CARDANO_NODE_SOCKET_PATH($r) Required for status, delegate, and undelegate
    ($f)CARDANO_NODE_NETWORK_ID($r)  Available; mirrors TESTNET_MAGIC

  ($h)Secrets Layout($r)

    ($p)secrets/envs/<env>/pool-delegations/($r)
      ($p)pool-delegations.mnemonic($r)       24-word BIP39 mnemonic \(sops-encrypted\)
      ($p)<i>/($r)
        ($p)payment.addr($r)                  Written by generate-accounts; payment-only address
        ($p)stake.addr($r)                    Written by generate-accounts; stake address
        ($p)delegation.addr($r)               Written by generate-accounts; fund this address!

  ($h)Workflow($r)

    ($n)1.($r) ($c)generate-mnemonic($r) — create and sops-encrypt a new BIP39 mnemonic
    ($n)2.($r) ($c)generate-accounts($r)    — derive and save account addresses
    ($n)3.($r) Fund                 — send ADA to each delegation address \(from faucet / wallet\)
         ($d)for i in {0..19}; do echo \"Funding account $i\"; just fund-transfer $ENV $\(scripts/playground/pool-delegations.nu address -i $i\) $LOVELACE; echo; done($r)
    ($n)4.($r) ($c)status($r)              — confirm balances arrived on-chain
    ($n)5.($r) ($c)delegate($r)            — register + delegate each account to chosen pools
    ($n)6.($r) ($c)status($r)              — verify delegation is active
    ($n)7.($r) ($c)dedelegate($r)          — remove pool delegation \(stake key stays registered\)
    ($n)8.($r) ($c)deregister($r)          — when done, deregister stake key + reclaim 2 ADA deposit

  ($h)Examples($r) ($d)\(with $ENV=preview set in the devShell\)($r)

    ($d)$($r) ($c)pool-delegations.nu generate-mnemonic($r)        ($d)# uses $ENV($r)
    ($d)$($r) ($c)pool-delegations.nu preview generate-mnemonic($r)
    ($d)$($r) ($c)pool-delegations.nu generate-accounts($r)        ($d)# uses $ENV($r)
    ($d)$($r) ($c)pool-delegations.nu preview generate-accounts($r) ($f)-n($r) 10
    ($d)$($r) ($c)pool-delegations.nu status($r)
    ($d)$($r) ($c)pool-delegations.nu preview status($r)
    ($d)$($r) ($c)pool-delegations.nu status($r) ($f)--dbsync($r) preview1-dbsync-a-1  ($d)# with last-forged-block from dbsync($r)
    ($d)$($r) ($c)pool-delegations.nu address($r) ($f)-i($r) 0             ($d)# prints funding address to stdout($r)
    ($d)$($r) ($c)pool-delegations.nu delegate($r) ($f)-p($r) pool1abc... ($f)-i($r) 0
    ($d)$($r) ($c)pool-delegations.nu preview delegate($r) ($f)-p($r) pool1abc... ($f)--dry-run($r)
    ($d)$($r) ($c)pool-delegations.nu dedelegate($r) ($f)-i($r) 2
    ($d)$($r) ($c)pool-delegations.nu preview dedelegate($r) ($f)-i($r) 2 ($f)--dry-run($r)
    ($d)$($r) ($c)pool-delegations.nu deregister($r) ($f)-i($r) 0
    ($d)$($r) ($c)pool-delegations.nu preview deregister($r) ($f)-i($r) 0 ($f)--dry-run($r)
    ($d)$($r) ($c)pool-delegations.nu defund($r) ($f)-d($r) addr_test1qz... ($f)-i($r) 0
    ($d)$($r) ($c)pool-delegations.nu preview defund($r) ($f)-d($r) addr_test1qz... ($f)-i($r) 0 ($f)--dry-run($r)

  ($h)Notes($r)

    - Each account is self-funded: its own payment key \(from the mnemonic\)
      signs delegation transactions. No separate faucet key is required.
    - Registration deposit: 2 ADA \(refunded on deregistration\).
    - Private key material is written only to short-lived mktemp files
      deleted immediately after use.
    - All secrets under the secrets tree are sops-encrypted at rest with age keys.
"
}

# Cardano Pool Delegation Manager
def main [
    environment?: string          # Playground environment, e.g. "preview"; falls back to $ENV
    subcommand?: string           # generate-mnemonic | generate-accounts | status | address | delegate | dedelegate | deregister | defund
    --num-accounts (-n): int       # Accounts: generate-accounts defaults to 3, status defaults to existing count
    --index (-i): int              # Account index (delegate, dedelegate, deregister, defund)
    --pool-id (-p): string        # Pool ID in bech32 or hex (delegate)
    --dest-address (-d): string   # Destination address (defund)
    --dry-run                     # Show details without submitting
    --confirm                     # Review transaction before submitting
    --dbsync: string              # Dbsync SSH hostname for last-forged-block enrichment (status only)
] {
    let known = ["generate-mnemonic", "generate-accounts", "status", "address", "delegate", "dedelegate", "deregister", "defund"]

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
            error make --unspanned { msg: "Provide an <environment> argument (e.g. \"preview\") or set the ENV environment variable" }
        }
        $env.ENV
    } else {
        resolve-env $environment
    }
    let resolved_cmd = if $subcmd_in_env_slot { $environment } else { $subcommand }

    check-network $resolved_env

    match $resolved_cmd {
        null                => { show-help }
        "generate-mnemonic" => { do-generate-mnemonic $resolved_env }
        "generate-accounts" => { do-generate-accounts $resolved_env ($num_accounts | default 3) }
        "status"     => {
            let n = if $num_accounts != null { $num_accounts } else {
                let found = (count-accounts $resolved_env)
                if $found == 0 {
                    error make --unspanned { msg: $"No account directories found under (secrets-root $resolved_env)/. Run 'generate-accounts' first or pass -n." }
                }
                $found
            }
            do-status $resolved_env $n $dbsync
        }
        "address"    => {
            if $index == null { error make --unspanned { msg: "Must provide --index (-i) for address" } }
            do-address $resolved_env $index
        }
        "delegate"   => {
            if $index == null { error make --unspanned { msg: "Must provide --index (-i) for delegate" } }
            do-delegate $resolved_env $index $pool_id $dry_run $confirm
        }
        "dedelegate" => {
            if $index == null { error make --unspanned { msg: "Must provide --index (-i) for dedelegate" } }
            do-dedelegate $resolved_env $index $dry_run $confirm
        }
        "deregister" => {
            if $index == null { error make --unspanned { msg: "Must provide --index (-i) for deregister" } }
            do-deregister $resolved_env $index $dry_run $confirm
        }
        "defund"     => {
            if $index == null { error make --unspanned { msg: "Must provide --index (-i) for defund" } }
            do-defund $resolved_env $index $dest_address $dry_run $confirm
        }
        _            => {
            print $"(ansi red)Unknown subcommand: ($resolved_cmd)(ansi reset)"
            print "Valid subcommands: generate-mnemonic, generate-accounts, status, address, delegate, dedelegate, deregister, defund"
        }
    }
}
