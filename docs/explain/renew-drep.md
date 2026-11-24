# Renew a DRep

Run from the repository root with the desired node environment sourced and its
matching `cardano-cli` on PATH. The script checks the network environment and tip,
queries the registered DRep, and preserves its existing metadata URL and hash
(or preserves an absent anchor). It does not cast a vote or submit automatically.

```bash
scripts/playground/renew-drep.nu preview --dry-run
scripts/playground/renew-drep.nu preview
```

For Leios, source its node environment first (magic 164 and its socket), then
select the prototype tooling from the repository pin in Bash:

```bash
source scripts/playground/leios-pin.sh
scripts/playground/renew-drep.nu leios --dry-run
scripts/playground/renew-drep.nu leios
```

Alternatively, pass `--cli /path/to/leios/cardano-cli` to either invocation.
The script reads the current era from the node tip, so Leios queries,
certificate creation, and transaction commands use `dijkstra`. The selected
CLI is also used in the printed review and submission commands. A mainline CLI
with Dijkstra support alone is not a substitute for the Leios prototype CLI.

Defaults are `secrets/envs/<environment>/drep/drep-0.{vkey,skey}` and
`secrets/envs/<environment>/utxo-keys/rich-utxo.{vkey,skey}`. Override these with
`--drep-key` and `--payment-key` (key stems, without extensions). Both SOPS binary
JSON envelopes and plaintext key envelopes are supported.

The dry run decrypts only the verification key when necessary. A normal run
selects the smallest plain ADA input that can fund the transaction, creates an
update certificate, and signs with both the payment and DRep keys. No new DRep
deposit is required. Decrypted copies are held in a private temporary directory
and removed on success, handled errors, or INT/TERM/HUP interruption by a Bash
supervisor. SIGKILL of the supervisor or host failure can still prevent cleanup.

Artifacts are saved under a unique `workbench/drep-renewal-*` directory, including
`update.cert`, `renewal.raw`, `renewal.signed`, and `README.md`. Use `--output` to
choose a new directory. Review the certificate and transaction, then use the
printed Bash submission command. Submit promptly: funding inputs, protocol
parameters, or the DRep's anchor may change after preparation.

After confirmation, rerun `scripts/playground/query-delegation.nu preview` to
check the expiry and active status. Renewal restores voting eligibility, so it
can affect governance denominators even though it casts no vote. The script does
not transfer additional funds or change delegations.

## Validity and transaction review

The default transaction validity ends **12 hours after preparation**. Override it
with `--valid-for 2hr`, for example. The script uses the node's `query slot-number`
to translate the UTC deadline, rather than assuming a slot length. If the node
reports `PastHorizon`, the script halves the requested window until it can map
the deadline, printing a warning with the shortened validity. This is useful on
Leios, where the forecast horizon can be shorter than 12 hours. It stops if a
window of one minute or less still fails; unrelated query errors fail immediately.
The actual deadline and slot are printed and saved in the report. You can also
request a short window explicitly with `--valid-for 30min`.

Before signing, both signing keys are checked against their verification keys.
Different extended/non-extended representations are rejected rather than guessed.

The output and generated README print the exact CLI path and review command:

```bash
cardano-cli debug transaction view --tx-file /path/to/renewal.signed
```

Check the update certificate, preserved anchor, funding input, change address,
fee, and validity interval before using the separately printed submission command.
Viewing a transaction requires neither a node socket nor network flags. A validity
window limits stale submissions but does not prevent another anchor update during
that window: rebuild if the DRep metadata has changed since preparation.

## Offline regression tests

```bash
nu --no-config-file scripts/playground/tests/test-renew-drep.nu
```

These use fake keys and a mock CLI: anchor preservation (including null), absent
registration, key mismatch, missing funds, signing failure, dry run, termination
cleanup, validity flags, review output, and no automatic submission.
