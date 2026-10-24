# Governance action submission

Run `scripts/gov/submit-action.nu` from the repository root in the devShell.
It uses native `cardano-cli` action flags without shell evaluation, queries the
current era and governance deposit, verifies the published rationale, and builds
and signs a transaction. Submission requires `--submit`, followed by confirmation
(or `--submit --yes` for unattended use).

## Musashi F2 example

In Bash, select the network and the Leios prototype CLI first:

```bash
source <(just set-default-cardano-env leios)
source scripts/playground/leios-pin.sh

scripts/gov/submit-action.nu leios pparams \
  --anchor-url ipfs://QmZz6G5DMHzMRQEVzU1LnaDJhMZS3gbmvRaxvDsBudUms5 \
  --rationale-file 2026-10-23-leios-rationale-signed.json \
  --stake-key secrets/groups/leios1/no-deploy/leios1-bp-a-1-owner-stake \
  --max-endorser-block-txs-size 2000000 \
  --max-endorser-block-references-size 308000 \
  --dry-run
```

Without `--previous-action`, the script queries `gov-state` and shows the entry
at `nextRatifyState.nextEnactState.prevGovActionIds` for the action's purpose:
`PParamUpdate`, `HardFork`, `Constitution`, or `Committee` (also no-confidence).
Press Enter to accept the suggested `TXID#INDEX`, or type an override. An explicit
null suggests `none`; missing fields or failed queries leave manual entry required.
If the suggested action is still in the proposals set, it is labeled as projected
ratification state rather than confirmed enactment. A build checks the selected
parent against the current ledger state.

Use `--previous-action TXID#INDEX` or `--previous-action none` to skip the lookup
and prompt. Info and treasury actions do not have a previous-action link.

Remove `--dry-run` to build and sign. Add `--submit` to build, sign, review and
submit. `--yes` only skips submission confirmation; it does not select keys or
the previous action for you. A dry run still requires a synced local node and a
reachable rationale URL, but does not decrypt keys, build, sign or submit.

## Other actions and options

Aliases: `pparams`, `info`, `hardfork`, `constitution`, `committee`,
`no-confidence`, `treasury`. The corresponding full CLI action names also work.
Unknown flags are passed to the selected action command, so new protocol
parameters do not require changes to this script. Use the selected CLI's
`<era> governance action <command> --help` for those flags.

```bash
scripts/gov/submit-action.nu preview info --anchor-url ipfs://YOUR_CID
scripts/gov/submit-action.nu --help
```

- Payment defaults to `secrets/envs/<env>/utxo-keys/rich-utxo`; override with
  `--payment-key <stem>`. Deposit return keys are discovered from pool owner keys
  and selected interactively unless `--stake-key <stem>` is supplied.
- Stems omit `.vkey`/`.skey`. Both SOPS-encrypted repository keys and plaintext
  CLI key envelopes are supported. Only the payment signing key is needed;
  returning a proposal deposit does not require a stake-key signature.
- For parameter updates and treasury withdrawals, the live constitution decides
  whether guardrails are needed. The script searches `docs/environments/<env>`
  and `docs/environments-pre/<env>` for a matching script, or accepts
  `--guardrails-file`. It verifies the hash before use. The default redeemer is
  `{}`; override with `--guardrails-redeemer <json file>`.
- A new constitution's script hash is an action-specific
  `--constitution-script-hash` flag; it is not the guardrails witness for a
  parameter change.
- The payer needs a plain ADA UTxO covering the deposit and fee. Guardrails also
  require a separate plain ADA collateral UTxO of at least 10 ADA. The script
  does not consolidate funds or automatically select token-bearing outputs.
- `--anchor-url` accepts a URL or bare CID. IPFS uses `IPFS_GATEWAY_URI`, default
  `https://gateway.pinata.cloud`. The exact downloaded bytes are hashed and saved.
  Optional `--anchor-hash` and `--rationale-file` must match the published content.
  The document must contain the CIP-108 proposal body fields; this is not a full
  JSON-LD or author-signature validator. Use `rationale.nu` to sign/upload first.
- Mainnet uses `--mainnet`; other known networks use their configured magic.
  `EXTRA_ENV_MAGIC` can add networks as a JSON object. `--cli` selects a binary;
  the script never silently downloads or changes your CLI pin.

Each build gets a new directory under `workbench/gov-actions/`, or the new
directory specified by `--out-dir`. Existing directories are never overwritten.
It contains the proposal, current protocol parameters, rationale, optional
guardrails script/redeemer, unsigned body, signed transaction and `README.md`.
No private keys are copied there. Decrypted keys use a private temporary
directory, removed on success or caught errors. As with other CLI tools, a hard
process kill can bypass cleanup.

Successful submission means the node accepted the transaction; it does not
prove on-chain inclusion. The report contains the action ID (`TXID#0`) for
subsequent confirmation and voting with `scripts/gov/vote.nu`.

## Offline checks

```bash
nu --no-config-file scripts/gov/tests/test-submit-action.nu
```

The tests mock the CLI, IPFS fetch and key decryption. They never access real
keys or a node. The runner and mocks are written in Nushell; Python is not
required. Invoke a specific `nu` binary to test that version; child processes
use the same binary. The runner uses coreutils `timeout` to bound each invocation.
