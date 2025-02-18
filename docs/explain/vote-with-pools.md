# Vote With Pools

To use the playground pools to vote on governance actions, the simplest way to
do so is to use the just recipe `vote-with-pool` which will automate governance
action review, vote generation, transaction build, transaction review and
finally transaction submission.

For a detailed look a manually voting with a pool, the following procedure may
be used.

Set env vars for voting.  In this example, we'll use preview and a given
action id and index.  Adjust accordingly for your use case.
```bash
export ENV=preview
export CARDANO_NODE_NETWORK_ID=2
export TESTNET_MAGIC=2
export ACTION_ID=9ac7d4f3bb9367a35c3b204e96bbee979f7e7a5aeb004429bccb1ba911805a2c
export ACTION_IDX=0
```

If not already started, start node and wait until the chain is sync'd to tip.
```bash
just start-node $ENV
just query-tip $ENV
```

Use the cardano-cli or cardano-cli-ng version of CLI as appropriate for your
environment.

Review the action information and proceed if satisfied.
```bash
cardano-cli-ng conway query gov-state \
  | jq \
    --arg actionId "$ACTION_ID" \
    --arg actionIdx "$ACTION_IDX" \
    '.proposals
      | map(
        select(
          .actionId.txId == $actionId
            and .actionId.govActionIx == ($actionIdx | tonumber)
        )
      )' \
  | tee gov-state-before-vote.json
```

Generate a vote file.  Adjust the pool machine secret path(s) if needed.
```bash
cardano-cli-ng conway governance vote create \
    --yes \
    --governance-action-tx-id "$ACTION_ID" \
    --governance-action-index "$ACTION_IDX" \
    --cold-verification-key-file <(just sops-decrypt-binary secrets/groups/${ENV}1/deploy/${ENV}1-bp-a-1-cold.vkey) \
    --out-file "$ACTION_ID-${ENV}1.vote"

cardano-cli-ng conway governance vote create \
    --yes \
    --governance-action-tx-id "$ACTION_ID" \
    --governance-action-index "$ACTION_IDX" \
    --cold-verification-key-file <(just sops-decrypt-binary secrets/groups/${ENV}2/deploy/${ENV}2-bp-b-1-cold.vkey) \
    --out-file "$ACTION_ID-${ENV}2.vote"

cardano-cli-ng conway governance vote create \
    --yes \
    --governance-action-tx-id "$ACTION_ID" \
    --governance-action-index "$ACTION_IDX" \
    --cold-verification-key-file <(just sops-decrypt-binary secrets/groups/${ENV}3/deploy/${ENV}3-bp-c-1-cold.vkey) \
    --out-file "$ACTION_ID-${ENV}3.vote"
```

Votes files can be viewed with the following:
```bash
cardano-cli-ng conway governance vote view --vote-file "$ACTION_ID-${ENV}1.vote"
cardano-cli-ng conway governance vote view --vote-file "$ACTION_ID-${ENV}2.vote"
cardano-cli-ng conway governance vote view --vote-file "$ACTION_ID-${ENV}3.vote"
```

Prepare to build a transaction:
```bash
RICH_ADDR=$(just sops-decrypt-binary secrets/envs/${ENV}/utxo-keys/rich-utxo.addr)

# View available UTxO inputs to fund a voting transaction
# and set TXIN to this selected UTxO
cardano-cli-ng conway query utxo --address "$RICH_ADDR"

# Or, select the smallest available UTxO greater than 5 ADA automatically with jq:
TXIN=$(cardano-cli-ng conway query utxo \
  --address "$RICH_ADDR" \
  --out-file /dev/stdout \
  | jq -r '.
    | to_entries
    | map(select(.value.value.lovelace > 5000000))
    | sort_by(.value.value.lovelace)[0].key')
```

Build the transaction:
```bash
cardano-cli-ng conway transaction build \
  --tx-in "$TXIN" \
  --change-address "$RICH_ADDR" \
  --testnet-magic "$TESTNET_MAGIC" \
  --vote-file "$ACTION_ID-${ENV}1.vote" \
  --vote-file "$ACTION_ID-${ENV}2.vote" \
  --vote-file "$ACTION_ID-${ENV}3.vote" \
  --witness-override 4 \
  --out-file vote-tx.raw
```

Sign the transaction:
```bash
cardano-cli-ng conway transaction sign \
  --tx-body-file vote-tx.raw \
  --signing-key-file <(just sops-decrypt-binary secrets/envs/${ENV}/utxo-keys/rich-utxo.skey) \
  --signing-key-file <(just sops-decrypt-binary secrets/groups/${ENV}1/no-deploy/${ENV}1-bp-a-1-cold.skey) \
  --signing-key-file <(just sops-decrypt-binary secrets/groups/${ENV}2/no-deploy/${ENV}2-bp-b-1-cold.skey) \
  --signing-key-file <(just sops-decrypt-binary secrets/groups/${ENV}3/no-deploy/${ENV}3-bp-c-1-cold.skey) \
  --testnet-magic "$TESTNET_MAGIC" \
  --out-file vote-tx.signed
```

View the transaction details before submitting:
```bash
cardano-cli-ng debug transaction view \
  --tx-file vote-tx.signed
```

Submit the transaction:
```bash
cardano-cli-ng conway transaction submit \
  --tx-file vote-tx.signed
```

Verify three new `stakePoolVotes` are now visible in the action gov-state
```bash
cardano-cli-ng conway query gov-state \
  | jq \
    --arg actionId "$ACTION_ID" \
    --arg actionIdx "$ACTION_IDX" \
    '.proposals
      | map(
        select(
          .actionId.txId == $actionId
            and .actionId.govActionIx == ($actionIdx | tonumber)
        )
      )' \
  | tee gov-state-after-vote.json

icdiff gov-state-before-vote.json gov-state-after-vote.json
```

Clean unwanted files:
```bash
rm $ACTION_ID-${ENV}?.vote
rm vote-tx.*
rm gov-state-*.json
```
