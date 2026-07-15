#!/usr/bin/env nu
# CC voting-rationale anchor helper
#
# Automates the tedious CC rationale anchor process: sign a CIP-100/136
# rationale document, upload it to the self-hosted Kubo IPFS node, and emit the
# `ipfs://<CID>` anchor URL plus the locally-computed anchor-data hash — exactly
# what the voting flow needs. Replaces the manual sign-cc-rationale.sh + hand
# curl + copy-the-CID dance.
#
# The rationale doc itself (a CIP-136 JSON-LD file, by default ./rationale.json)
# is consumed AS-IS — edit its body (summary/rationaleStatement/...) beforehand.
# A signed sibling `<file>.signed` is produced and uploaded.
#
# SUBCOMMANDS:
#   rationale.nu sign <env> [--file rationale.json] [--cli cardano-cli]
#       Sign the rationale with the env's rationale-signer key (cardano-signer
#       --cip100), verify it, and write <file>.signed.
#
#   rationale.nu upload --file <file.signed> --creds-secret <sops-path>
#                       [--cid-version 0] [--no-pin]
#       Upload an (already signed) file to IPFS; prints `ipfs://<CID>`.
#
#   rationale.nu prepare <env> --creds-secret <sops-path> [--file rationale.json]
#                        [--cid-version 0] [--cli cardano-cli] [--verify]
#       Full chain: sign -> upload -> hash. Emits a JSON record on stdout:
#         {"anchorUrl": "ipfs://...", "signedFile": "...", "hash": "..."}
#       (all human progress goes to stderr). This is what `vote.nu
#       --rationale-file` consumes.
#
# CREDENTIALS: the IPFS node uses HTTP basic auth. --creds-secret points at a
# sops-encrypted file whose decrypted contents are a single `user:password`
# line (this is NOT the server-side htpasswd secret). It defaults to
# secrets/groups/misc1/no-deploy/misc1-metadata-a-1-ipfs-client (the shared node
# serves all testnets). Creds are passed to curl via a stdin config (-K -) so
# they never appear in the process list.
#
# DEPENDENCIES: just (sops-decrypt-binary), cardano-signer, cardano-cli, curl.
const ipfs_host = "https://ipfs.play.dev.cardano.org"
# Decrypt a sops-encrypted secret and return its trimmed contents as a string.
def secret-str [rel: string] {
  ^just sops-decrypt-binary $rel | into string | str trim
}
def main [] {
  print "CC rationale anchor helper. Subcommands: sign | upload | prepare."
  print "Run `rationale.nu <subcommand> --help` for details."
}
# Sign a rationale doc with the env's rationale-signer key; returns the signed
# file path. Mirrors scripts/playground/sign-cc-rationale.sh.
def 'main sign' [
  node_env: string            # Node environment (preprod, preview, ...)
  --file: path = "rationale.json"  # Rationale doc to sign
  --cli: string = "cardano-cli"    # cardano-cli binary (unused here; kept for symmetry)
] {
  if not ($file | path exists) {
    error make --unspanned {
      msg: $"Rationale file not found: ($file)"
    }
  }
  let signed = $"($file).signed"
  let tmp = (mktemp --directory)
  chmod 0700 $tmp
  try {
    # cardano-signer wants the raw skey in a file; rationale-signer.json holds it
    # under .output.skey (same extraction sign-cc-rationale.sh does).
    let skey_file = ($tmp | path join "rationale-signer.skey")
    # .output.skey may be a bech32 string OR a key-file object ({type,cborHex}).
    # Mirror `jq -r`: write strings raw, objects as JSON, so cardano-signer
    # --secret-key gets the right bytes either way.
    let skey = (secret-str $"secrets/envs/($node_env)/cc-keys/rationale-signer.json" | from json | get output.skey)
    (if ($skey | describe | str starts-with "string") { $skey } else {
      $skey | to json
    }) | save --raw --force $skey_file
    chmod 0600 $skey_file
    print -e $"Signing ($file) for env ($node_env)..."
    # `| ignore` keeps cardano-signer's stdout from polluting `prepare`'s JSON
    # output; the signed doc is written to --out-file regardless.
    (^cardano-signer sign --cip100 --data-file $file --secret-key $skey_file --author-name $"IO Labs Node SRE for ($node_env | str capitalize)" --replace --out-file $signed) | ignore
    # Verify the produced witness before trusting it.
    ^cardano-signer verify --cip100 --data-file $signed --json | from json | ignore
    print -e $"Signed + verified -> ($signed)"
  } catch {|err|
    rm --recursive --force --permanent $tmp
    error make --unspanned {
      msg: $err.msg
    }
  }
  rm --recursive --force --permanent $tmp
  $signed
}
# Upload a file to the IPFS node and print `ipfs://<CID>` on stdout.
def 'main upload' [
  --file: path                     # File to upload (typically <rationale>.signed)
  --creds-secret: path = "secrets/groups/misc1/no-deploy/misc1-metadata-a-1-ipfs-client"  # sops file with a `user:password` line
  --cid-version: int = 0           # IPFS CID version (v0 to fit Cardano anchor-URL field length)
  --no-pin                         # Do not pin on the node (pinned by default)
] {
  let cid = (upload-file $file $creds_secret $cid_version (not $no_pin))
  print $"ipfs://($cid)"
}
# Full chain: sign -> upload -> hash. Emits a JSON record on stdout; progress to
# stderr. Consumed by vote.nu --rationale-file.
def 'main prepare' [
  node_env: string                 # Node environment
  --creds-secret: path = "secrets/groups/misc1/no-deploy/misc1-metadata-a-1-ipfs-client"  # sops file with a `user:password` line
  --file: path = "rationale.json"  # Rationale doc to sign + upload
  --cid-version: int = 0           # IPFS CID version (v0 to fit Cardano anchor-URL field length)
  --cli: string = "cardano-cli"    # cardano-cli binary used for hashing
  --verify                         # After upload, fetch via gateway and confirm the hash matches
] {
  if ($creds_secret | is-empty) {
    error make --unspanned {msg: "prepare requires --creds-secret <sops-path> (a file with a user:password line)"}
  }
  let signed = (main sign $node_env --file $file --cli $cli)
  let cid = (upload-file $signed $creds_secret $cid_version true)
  let url = $"ipfs://($cid)"
  # Hash the exact local bytes we uploaded — deterministic, no gateway round-trip.
  let hash = (^$cli hash anchor-data --file-binary $signed | into string | str trim)
  print -e $"Anchor: (ansi green)($url)(ansi reset)  hash: ($hash)"
  if $verify {
    print -e "Verifying the anchor is fetchable and its hash matches..."
    let fetched = (with-env {IPFS_GATEWAY_URI: "https://ipfs.io"} {
      try { ^$cli hash anchor-data --url $url | into string | str trim } catch { "" }
    })
    if ($fetched | is-empty) {
      print -e $"(ansi yellow)Warning: could not fetch ($url) via ipfs.io yet \(propagation lag is normal\). Local hash stands.(ansi reset)"
    } else if $fetched != $hash {
      error make --unspanned {
        msg: $"Anchor hash mismatch: local ($hash) != fetched ($fetched). Do not vote with this anchor."
      }
    } else {
      print -e $"(ansi green)Verified: gateway hash matches.(ansi reset)"
    }
  }
  {
    anchorUrl: $url
    signedFile: $signed
    hash: $hash
  } | to json
}
# ─── internals ────────────────────────────────────────────────────────────────
# POST a file to the IPFS node's /api/v0/add and return the CID. Credentials are
# fed to curl through a stdin config so they never hit the process list.
def upload-file [
  file: path
  creds_secret: path
  cid_version: int
  pin: bool
] {
  if ($creds_secret | is-empty) {
    error make --unspanned {msg: "upload requires --creds-secret <sops-path> (a file with a user:password line)"}
  }
  if not ($file | path exists) {
    error make --unspanned {
      msg: $"Upload file not found: ($file)"
    }
  }
  let creds = (secret-str $creds_secret)
  if not ($creds | str contains ":") {
    error make --unspanned {
      msg: $"Decrypted ($creds_secret) is not in user:password form."
    }
  }
  let url = $"($ipfs_host)/api/v0/add?cid-version=($cid_version)&pin=($pin)"
  print -e $"Uploading ($file) to ($ipfs_host) \(cid-version ($cid_version), pin ($pin)\)..."
  let resp = ($"user = \"($creds)\"\n" | ^curl -sS --fail-with-body -K - -X POST -F $"file=@($file)" $url)
  let cid = (
    $resp | lines | where {|l| ($l | str trim) != "" } | last | from json | get Hash
  )
  if ($cid | is-empty) {
    error make --unspanned {
      msg: $"Upload did not return a CID. Response: ($resp)"
    }
  }
  $cid
}
