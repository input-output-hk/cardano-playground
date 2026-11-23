#!/usr/bin/env nu
# Renew a registered DRep without changing its anchor or casting a vote.
# Guide: docs/explain/renew-drep.md
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
# Build and sign only; submission is always a separate explicit command.
def main [
  environment: string
  --drep-key: string = "" # Key stem; defaults to secrets/envs/<env>/drep/drep-0
  --payment-key: string = "" # Key stem; defaults to secrets/envs/<env>/utxo-keys/rich-utxo
  --dry-run # Query public state only; no signing keys decrypted
  --output: string = "" # New output directory; must not already exist
] {
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
  let cli = which cardano-cli | first | get path
  let net = if $environment == 'mainnet' { [--mainnet] } else { [--testnet-magic, $magic] }
  let tip = ^$cli latest query tip ...$net | from json
  if ($tip.syncProgress | into float) < 100 { fail "Wait for the node to reach 100% sync." }
  let era = $tip.era | str downcase
  let drep = if ($drep_key | is-empty) { $"secrets/envs/($environment)/drep/drep-0" } else { $drep_key }
  let payer = if ($payment_key | is-empty) { $"secrets/envs/($environment)/utxo-keys/rich-utxo" } else { $payment_key }
  let tmp = ^mktemp -d | str trim
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
    print {environment: $environment, era: $era, epoch: $tip.epoch, expiry: $info.expiry, status: $status, anchor: $anchor, payment_key: $payer}
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
    let address = ^$cli address build --payment-verification-key-file $pvkey ...$net | str trim
    let utxos = ^$cli $era query utxo --address $address ...$net --output-json | from json
    let candidates = $utxos | transpose txin output | where {|u|
      ($u.output.value | columns) == [lovelace] and ($u.output.inlineDatum? | is-empty) and ($u.output.datumhash? | is-empty) and ($u.output.referenceScript? | is-empty)
    } | sort-by {|u| $u.output.value.lovelace }
    mut funded = false
    for candidate in $candidates {
      let built = ^$cli $era transaction build ...$net --tx-in $candidate.txin --change-address $address --witness-override 2 --certificate-file $cert --out-file $body | complete
      if $built.exit_code == 0 {
        $funded = true
        print $built.stdout
        break
      }
      let diagnostic = $built.stdout + $built.stderr
      if $diagnostic !~ '(?is)(The net balance of the transaction is negative|balance does not meet the minimum UTxO threshold)' { fail $diagnostic }
    }
    if not $funded { fail "No single plain ADA input can cover the fee and minimum change." }
    let skey = key-file $"($drep).skey" $tmp
    let pskey = key-file $"($payer).skey" $tmp
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
    let report = $"# DRep renewal

Environment: ($environment)

DRep: ($state | first | get 0 | to json --raw)

Previous expiry: ($info.expiry)

Preserved anchor: ($anchor | to json --raw)

Transaction ID: ($txid)

Built and signed; NOT submitted. Review the certificate and transaction before submission.

```bash
($command)
```
"
    $report | save ($out | path join 'README.md')
    print $"Transaction ID: ($txid)
Artifacts: ($out)
Not submitted. After review, submit with:

($command)"
  } catch {|err|
    rm --recursive --force $tmp
    fail $err.msg
  }
}
