#!/usr/bin/env nu
# Renew a registered DRep without changing its anchor or casting a vote.
# Guide: docs/explain/renew-drep.md
const script_path = path self
def fail [message: string]: nothing -> any { error make --unspanned {msg: $message} }
# Quote arguments for Bash, including paths containing apostrophes.
def shell-quote [value: string]: nothing -> string {
  if $value =~ '^[a-zA-Z0-9_./:=#-]+$' { return $value }
  "'" + ($value | str replace --all "'" "'\"'\"'") + "'"
}
# Both plaintext CLI envelopes and the repository's SOPS binary envelopes work.
# Private material is only written inside a mode-0700 temporary directory.
def key-file [source: string, tmp: string]: nothing -> string {
  if not ($source | path exists) { fail $"Key file not found: ($source)" }
  let doc = open --raw $source | from json
  if "sops" not-in ($doc | columns) { return ($source | path expand) }
  let dest = $tmp | path join (random uuid)
  ^just sops-decrypt-binary $source | save --raw $dest
  ^chmod 0600 $dest
  $dest
}
# Derive the public key rather than trusting separately supplied key files.
def check-key-pair [cli: string, keys: record] {
  let derived = $keys.tmp | path join (random uuid)
  ^$cli key verification-key --signing-key-file $keys.skey --verification-key-file $derived
  let expected = open --raw $keys.vkey | from json
  let actual = open --raw $derived | from json
  if $expected.type != $actual.type or ($expected.cborHex | str downcase) != ($actual.cborHex | str downcase) {
    fail $"($keys.label) signing/verification key mismatch (or different extended-key representation)."
  }
}
# Build and sign only; submission is always a separate explicit command.
def main [
  environment: string
  --cli: string = "cardano-cli" # Executable or path; use the Leios-pinned CLI for leios
  --drep-key: string = "" # Key stem; defaults to secrets/envs/<env>/drep/drep-0
  --payment-key: string = "" # Key stem; defaults to secrets/envs/<env>/utxo-keys/rich-utxo
  --valid-for: duration = 12hr # Transaction validity from preparation time
  --private-temp: string = "" # Internal: private directory owned by cleanup supervisor
  --dry-run # Query public state only; no signing keys decrypted
  --output: string = "" # New output directory; must not already exist
] {
  if $valid_for <= 0sec { fail "--valid-for must be positive." }
  if ($private_temp | is-empty) {
    # Bash owns the temporary directory so it can clean up even when Nu is
    # interrupted. SIGKILL of the supervisor or host failure remains untrappable.
    let supervisor = 'set -eu; umask 077; tmp=$(mktemp -d); child=""; cleanup() { rm -rf -- "$tmp"; }; stop() { if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; exit 130; }; trap cleanup EXIT; trap stop INT TERM HUP; "$@" --private-temp "$tmp" & child=$!; set +e; wait "$child"; rc=$?; exit "$rc"'
    let args = [
      $nu.current-exe
      --no-config-file
      $script_path
      $environment
      --cli
      $cli
      --drep-key
      $drep_key
      --payment-key
      $payment_key
      --output
      $output
      --valid-for
      ($valid_for | into string)
    ] | append (if $dry_run { [--dry-run] } else { [] })
    ^bash -c $supervisor renew-drep ...$args
    return
  }
  let magics = {
    mainnet: "764824073"
    preview: "2"
    preprod: "1"
    sanchonet: "4"
    dijkstra: "6"
    leios: "164"
    demo: "42"
  }
  if $environment not-in ($magics | columns) { fail "Unknown environment" }
  let magic = $magics | get $environment
  if ($env.TESTNET_MAGIC? | default '' | into string) != $magic { fail $"Source the ($environment) node environment first." }
  if ($env.CARDANO_NODE_SOCKET_PATH? | is-empty) { fail "CARDANO_NODE_SOCKET_PATH is unset." }
  let cli_paths = which $cli
  if ($cli_paths | is-empty) { fail $"CLI not found: ($cli). For Leios, source scripts/playground/leios-pin.sh or pass --cli /path/to/cardano-cli." }
  let cli = $cli_paths | first | get path | path expand
  let net = if $environment == 'mainnet' { [--mainnet] } else { [--testnet-magic, $magic] }
  let tip = ^$cli latest query tip ...$net | from json
  if ($tip.syncProgress | into float) < 100 { fail "Wait for the node to reach 100% sync." }
  let era = $tip.era | str downcase
  let prepared = date now | date to-timezone UTC
  mut window = $valid_for
  mut expires = ''
  mut invalid_hereafter = 0
  # Short-epoch networks may not forecast 12 hours ahead. Ask the node each
  # time rather than extrapolating slot lengths beyond its known horizon.
  loop {
    $expires = $prepared + $window | format date '%Y-%m-%dT%H:%M:%SZ'
    let result = ^$cli $era query slot-number $expires ...$net | complete
    if $result.exit_code == 0 {
      $invalid_hereafter = $result.stdout | str trim | into int
      break
    }
    let diagnostic = $result.stdout + $result.stderr
    if $diagnostic !~ '(PastHorizon|Past horizon)' { fail $diagnostic }
    if $window <= 1min { fail "Node cannot forecast even this short validity window. Check node sync and retry later." }
    $window = $window / 2
  }
  if $window < $valid_for {
    print --stderr $"Warning: requested validity ($valid_for) exceeds the node forecast horizon; shortened to ($window), expiring ($expires)."
  }
  if $invalid_hereafter <= $tip.slot { fail "Validity deadline is not after the node tip." }
  let drep = if ($drep_key | is-empty) { $"secrets/envs/($environment)/drep/drep-0" } else { $drep_key }
  let payer = if ($payment_key | is-empty) { $"secrets/envs/($environment)/utxo-keys/rich-utxo" } else { $payment_key }
  let tmp = $private_temp
  ^chmod 0700 $tmp
  try {
    let vkey = key-file $"($drep).vkey" $tmp
    let state = ^$cli $era query drep-state --drep-verification-key-file $vkey ...$net | from json
    if ($state | length) != 1 { fail "Expected exactly one registered DRep; renewal cannot register an absent DRep." }
    let info = $state | first | get 1
    # Require the field: silently treating an unfamiliar schema as null could erase metadata.
    let anchor = $info | get anchor
    let anchor_args = if $anchor == null { [] } else {
      [
        --drep-metadata-url
        $anchor.url
        --drep-metadata-hash
        $anchor.dataHash
      ]
    }
    let status = if $info.expiry < $tip.epoch { 'expired' } else { 'active' }
    print {environment: $environment, era: $era, epoch: $tip.epoch, expiry: $info.expiry, status: $status, expires_utc: $expires, invalid_hereafter: $invalid_hereafter, anchor: $anchor, payment_key: $payer}
    if $dry_run {
      rm --recursive --force $tmp
      print "Dry run complete: anchor preserved; no signing keys decrypted or transaction built."
      return
    }
    let out = if ($output | is-empty) {
      $"workbench/drep-renewal-($environment)-(date now | format date '%Y%m%dT%H%M%S')-(random uuid)"
    } else { $output }
    if ($out | path exists) { fail $"Output already exists: ($out)" }
    mkdir $out
    let out = $out | path expand
    let cert = $out | path join 'update.cert'
    let body = $out | path join 'renewal.raw'
    let signed = $out | path join 'renewal.signed'
    ^$cli $era governance drep update-certificate --drep-verification-key-file $vkey ...$anchor_args --out-file $cert
    let pvkey = key-file $"($payer).vkey" $tmp
    let skey = key-file $"($drep).skey" $tmp
    let pskey = key-file $"($payer).skey" $tmp
    check-key-pair $cli {
      label: "DRep"
      vkey: $vkey
      skey: $skey
      tmp: $tmp
    }
    check-key-pair $cli {
      label: "Payment"
      vkey: $pvkey
      skey: $pskey
      tmp: $tmp
    }
    let address = ^$cli address build --payment-verification-key-file $pvkey ...$net | str trim
    let utxos = ^$cli $era query utxo --address $address ...$net --output-json | from json
    let candidates = $utxos | transpose txin output | where {|u|
      ($u.output.value | columns) == [lovelace] and ($u.output.inlineDatum? | is-empty) and ($u.output.datumhash? | is-empty) and ($u.output.referenceScript? | is-empty)
    } | sort-by {|u| $u.output.value.lovelace }
    mut funded = false
    for candidate in $candidates {
      let built = ^$cli $era transaction build ...$net --tx-in $candidate.txin --change-address $address --witness-override 2 --invalid-hereafter $invalid_hereafter --certificate-file $cert --out-file $body | complete
      if $built.exit_code == 0 {
        $funded = true
        print $built.stdout
        break
      }
      let diagnostic = $built.stdout + $built.stderr
      if $diagnostic !~ '(?is)(The net balance of the transaction is negative|balance does not meet the minimum UTxO threshold)' { fail $diagnostic }
    }
    if not $funded { fail "No single plain ADA input can cover the fee and minimum change." }
    ^$cli $era transaction sign --tx-body-file $body --signing-key-file $pskey --signing-key-file $skey ...$net --out-file $signed
    rm --recursive --force $tmp
    let txid = ^$cli $era transaction txid --tx-file $signed | str trim
    let command = [
      env
      $"CARDANO_NODE_SOCKET_PATH=($env.CARDANO_NODE_SOCKET_PATH)"
      $cli
      $era
      transaction
      submit
      ...$net
      --tx-file
      $signed
    ] | each {|arg| shell-quote $arg } | str join ' '
    let review = [
      $cli
      debug
      transaction
      view
      --tx-file
      $signed
    ] | each {|arg| shell-quote $arg } | str join ' '
    let report = $"# DRep renewal

Environment: ($environment)

DRep: ($state | first | get 0 | to json --raw)

Previous expiry: ($info.expiry)

Transaction valid before: ($expires), slot ($invalid_hereafter)

Preserved anchor: ($anchor | to json --raw)

Transaction ID: ($txid)

Built and signed; NOT submitted. Review the certificate and transaction before submission.

Review \(certificate, anchor, inputs, change, fee and validity\):

```bash
($review)
```

Submit:

```bash
($command)
```
"
    $report | save ($out | path join 'README.md')
    print $"Transaction ID: ($txid)
Artifacts: ($out)
Valid before: ($expires), slot ($invalid_hereafter)

Review transaction:
($review)

Not submitted. After review, submit with:

($command)"
  } catch {|err|
    rm --recursive --force $tmp
    fail $err.msg
  }
}
