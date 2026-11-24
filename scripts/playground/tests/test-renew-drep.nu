#!/usr/bin/env nu
# Offline tests; no network, real credentials, or transaction submission.
use std/assert
const script = path self ../renew-drep.nu
const mock = path self mock-renew-cli.sh
def main [] {
  let root = ^mktemp -d | str trim
  try {
    mkdir ($root | path join 'bin') ($root | path join 'private')
    cp $mock ($root | path join 'bin/cardano-cli')
    ^chmod +x ($root | path join 'bin/cardano-cli')
    cp ($root | path join "bin/cardano-cli") ($root | path join "bin/leios-cli")
    {type: MockVerificationKey, cborHex: "deadbeef"} | to json | save ($root | path join 'key.vkey')
    # Fake encrypted envelopes exercise the decrypted-file cleanup path.
    {
      sops: {}
    } | to json | save ($root | path join 'key.skey')
    '#!/usr/bin/env bash
cat "$TEST_ROOT/key.vkey"
' | save ($root | path join 'bin/just')
    ^chmod +x ($root | path join 'bin/just')
    for scenario in [
      success
      leios
      horizon-error
      horizon-exhausted
      null-anchor
      absent
      mismatch
      no-funds
      sign-failure
      dry-run
      interrupt
    ] {
      let args = [
        $script
        (if $scenario == 'leios' { 'leios' } else { 'preview' })
        --drep-key
        ($root | path join key)
        --payment-key
        ($root | path join key)
        --output
        ($root | path join $scenario)
      ] | append (if $scenario == 'dry-run' { [--dry-run] } else { [] }) | append (if $scenario == 'leios' {
        [
          --cli
          ($root | path join 'bin/leios-cli')
        ]
      } else { [] })
      '' | save --force ($root | path join calls)
      let result = with-env {
        PATH: ([$"($root)/bin"] | append $env.PATH)
        TEST_ROOT: $root
        SCENARIO: $scenario
        TMPDIR: ($root | path join private)
        TESTNET_MAGIC: (if $scenario == 'leios' { '164' } else { '2' })
        TEST_ERA: (if $scenario == 'leios' { 'Dijkstra' } else { 'Conway' })
        CARDANO_NODE_SOCKET_PATH: '/tmp/mock.socket'
      } {
        if $scenario == 'interrupt' {
          ^timeout --signal=TERM --kill-after=5s 1s $nu.current-exe --no-config-file ...$args | complete
        } else { ^$nu.current-exe --no-config-file ...$args | complete }
      }
      assert equal ($result.exit_code == 0) ($scenario in [success, leios, null-anchor, dry-run]) ($result.stdout + $result.stderr + (open --raw ($root | path join calls)))
      if $scenario == 'interrupt' {
        assert equal $result.exit_code 124 "Expected timeout-triggered termination"
        assert ((open --raw ($root | path join calls)) | str contains 'transaction sign')
      }
      assert equal (glob $"($root)/private/*") [] 'Decrypted temporary files remain'
      let calls = open --raw ($root | path join calls)
      assert (not ($calls | str contains 'transaction submit'))
      if $scenario in [success, leios, null-anchor] {
        assert ($calls | str contains '--invalid-hereafter 43300')
        assert ($calls | str contains '--witness-override 2')
        assert ($result.stdout | str contains 'debug transaction view --tx-file')
        assert (($calls | lines | where {|line| $line | str starts-with 'key verification-key' } | length) == 2)
        assert equal ($calls | str contains '--drep-metadata-url https://example.org/drep.json --drep-metadata-hash 0123456789abcdef') ($scenario in [success, leios])
      }
      if $scenario == 'leios' {
        assert ($result.stderr | str contains 'shortened to 1hr 30min')
        let deadlines = $calls | lines | where {|line| $line | str contains 'query slot-number' } | each {|line| $line | split row ' ' | get 3 | into datetime }
        assert equal ($deadlines | length) 4
        assert equal (($deadlines | get 0) - ($deadlines | get 3)) (10hr + 30min)
        assert (not ($calls | str contains 'conway'))
        assert ($calls | str contains 'dijkstra governance drep update-certificate')
        assert ($calls | str contains 'dijkstra transaction build --testnet-magic 164')
        assert ($result.stdout | str contains 'leios-cli dijkstra transaction submit --testnet-magic 164')
      }
      if $scenario in [horizon-error, horizon-exhausted] {
        assert (not ($calls | str contains 'transaction build'))
        let attempts = $calls | lines | where {|line| $line | str contains 'query slot-number' } | length
        if $scenario == 'horizon-error' { assert equal $attempts 1 } else { assert ($attempts <= 11) }
      }
      if $scenario == 'dry-run' { assert (not ($calls | str contains 'transaction build')) }
      print $"PASS ($scenario)"
    }
    rm --recursive --force $root
  } catch {|err|
    rm --recursive --force $root
    error make {
      msg: $err.msg
    }
  }
}
