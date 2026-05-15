#! /usr/bin/env nu

use std/log

def main []: nothing -> nothing {}

def 'main send-funds' [
	--funding-address-secret: path
	--funding-signing-key-secret: path
	--destination-address-secret: path
	--testnet-magic: int
	--utxo-count: int
	--utxo-lovelace: int = 10_000_000
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

	let funding_address = sops decrypt $funding_address_secret

	let destination_address = sops decrypt $destination_address_secret

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
		sops decrypt $funding_signing_key_secret | (
			^$'($starting_dir)/scripts/distribute.py'
			--testnet-magic $testnet_magic
			--signing-key-file /dev/stdin
			--address $funding_address
			--payments-json $'($tmp)/payments.json'
		)

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

def 'main get-funds' [
	--address-secret: path
	--testnet-magic: int
	--json
]: nothing -> record {
	let result = cardano-cli query utxo --address (sops decrypt $address_secret) --testnet-magic $testnet_magic
	| from json
	| items {|k v| {
		($k): $v.value.lovelace
	}}
	| into record

	if $json {
		$result | to json
	} else {
		$result
	}
}
