# Renew a DRep

Run from the repository root with the desired node environment sourced and its
matching `cardano-cli` on PATH. The script checks the network environment and tip,
queries the registered DRep, and preserves its existing metadata URL and hash
(or preserves an absent anchor). It does not cast a vote or submit automatically.

```bash
scripts/playground/renew-drep.nu preview --dry-run
scripts/playground/renew-drep.nu preview
```

Defaults are `secrets/envs/<environment>/drep/drep-0.{vkey,skey}` and
`secrets/envs/<environment>/utxo-keys/rich-utxo.{vkey,skey}`. Override these with
`--drep-key` and `--payment-key` (key stems, without extensions). Both SOPS binary
JSON envelopes and plaintext key envelopes are supported.

The dry run decrypts only the verification key when necessary. A normal run
selects the smallest plain ADA input that can fund the transaction, creates an
update certificate, and signs with both the payment and DRep keys. No new DRep
deposit is required. Decrypted copies are held in a private temporary directory
and removed on success or a handled error; forced termination can prevent cleanup.

Artifacts are saved under a unique `workbench/drep-renewal-*` directory, including
`update.cert`, `renewal.raw`, `renewal.signed`, and `README.md`. Use `--output` to
choose a new directory. Review the certificate and transaction, then use the
printed Bash submission command. Submit promptly: funding inputs, protocol
parameters, or the DRep's anchor may change after preparation.

After confirmation, rerun `scripts/playground/query-delegation.nu preview` to
check the expiry and active status. Renewal restores voting eligibility, so it
can affect governance denominators even though it casts no vote. The script does
not transfer additional funds or change delegations.
