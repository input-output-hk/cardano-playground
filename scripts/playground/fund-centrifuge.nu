#! /usr/bin/env nu
use std/log
# Decrypt only if the file is sops-encrypted; otherwise read as plaintext.
def maybe-decrypt [file: path]: nothing -> string {
  let raw = open --raw $file
  if ($raw | str contains '"sops":') or ($raw | str contains 'sops:') {
    sops decrypt $file | str trim
  } else {
    $raw | str trim
  }
}
def main []: nothing -> nothing { }
def 'main send-funds' [
  --funding-address-secret: path
  --funding-signing-key-secret: path
  --destination-address-secret: path
  --testnet-magic: int
  --utxo-count: int
  --utxo-lovelace: int = 10000000
]: nothing -> nothing {
  if ([
    $funding_address_secret
    $funding_signing_key_secret
    $destination_address_secret
    $testnet_magic
    $utxo_count
    $utxo_lovelace
  ] | any {is-empty}) {
    error make {msg: 'Missing CLI parameter.'}
  }
  # Resolve paths to absolute before the later `cd $tmp`, so relative paths
  # and bash process substitutions (/dev/fd/N) keep working.
  let funding_address_secret = $funding_address_secret | path expand
  let funding_signing_key_secret = $funding_signing_key_secret | path expand
  let destination_address_secret = $destination_address_secret | path expand
  if 'CARDANO_NODE_SOCKET_PATH' in $env {
    # --no-symlink: keep short symlinks intact for the AF_UNIX 108-byte limit.
    $env.CARDANO_NODE_SOCKET_PATH = ($env.CARDANO_NODE_SOCKET_PATH | path expand --no-symlink)
  }
  let funding_address = maybe-decrypt $funding_address_secret
  let destination_address = maybe-decrypt $destination_address_secret
  let payments = 1..$utxo_count | each {
		{$destination_address: $utxo_lovelace}
	}
  let starting_dir = pwd
  let tmp = mktemp --directory
  let cleanup = {
    cd $starting_dir
    rm --recursive --permanent $tmp
  }
  cd $tmp
  $payments | save $'($tmp)/payments.json'
  try {
    log info 'Building transactions'
    maybe-decrypt $funding_signing_key_secret | (^$'($starting_dir)/scripts/distribute.py' --testnet-magic $testnet_magic --signing-key-file /dev/stdin --address $funding_address --payments-json $'($tmp)/payments.json')
    log info $'Transactions built are in ($tmp)'
    if (input 'Submit transactions? (y/N) ') != y {
      do --env $cleanup
      return
    }
    log info 'Submitting transactions'
    for tx in (glob *.txsigned | sort --natural) {
      log info $'Submitting ($tx)'
      cardano-cli latest transaction submit --tx-file $tx
    }
  } catch {|err|
    do --env $cleanup
    print --stderr $err.rendered
    error make $err
  }
  do --env $cleanup
  log info $'Done. Use (ansi green)get-funds(ansi reset) next.'
}
def 'main get-funds' [--address-secret: path, --testnet-magic: int, --json]: nothing -> record {
  let address_secret = $address_secret | path expand
  let result = cardano-cli query utxo --address (maybe-decrypt $address_secret) --testnet-magic $testnet_magic | from json | items {|k v| {
		($k): $v.value.lovelace
	}} | into record
  if $json {
    $result | to json
  } else {
    $result
  }
}
