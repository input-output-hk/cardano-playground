# Debug chain quality

If there is an alert for chain quality on one of the playground networks, there
are a few steps that can be taken to quickly identify if there non-performant
pools contributing to the issue.

Assuming a dbsync machine has already been set up for the network of concern:
```bash
# Identify available dbsync machines
just list-machines | grep dbsync

# Open a psql session to a dbsync machine on the desired network
just dbsync-psql "$DBSYNC_NODE_NAME"
```

From within the psql session, analyze current pool forging:
```sql
-- Upon entering the psql session, some help instructions will describe how to
-- run set statements and execute prepared statements which can be used later.
--
-- First, just analyze forging:
execute show_current_forging;

-- Pools ordered from highest to lowest stake will be shown along with current
-- epochs blocks forged and last block forge time along with some other useful
-- information
 current_epoch |                         pool_id                          |    lovelace    | stake_pct | epoch_blocks | last_block |   last_block_time
---------------+----------------------------------------------------------+----------------+-----------+--------------+------------+---------------------
           574 | pool1p835jxsj8py5n34lrgk6fvpgpxxvh585qm8dzvp7ups37vdet5a | 38648462522444 |     8.521 |          335 |    2115686 | 2024-05-21 20:54:49
           574 | pool1vzqtn3mtfvvuy8ghksy34gs9g97tszj5f8mr3sn7asy5vk577ec | 35688133470659 |     7.868 |          324 |    2115688 | 2024-05-21 20:55:06
           574 | pool1ynfnjspgckgxjf2zeye8s33jz3e3ndk9pcwp0qzaupzvvd8ukwt | 21799162663240 |     4.806 |          190 |    2115675 | 2024-05-21 20:51:00
-- <snip>
           574 | pool1ghxsz57l4rhsju328dk0t8j3ycmz80xtf8w8xzpkk7pfwtca9u9 |  4994940729872 |     1.101 |           35 |    2115424 | 2024-05-21 19:07:50
           574 | pool1erufgazt3scqvjvsqv7ehayfscj93llzu3e6lknh2m6d5xcfjdr |  4925108817551 |     1.086 |              |    1853543 | 2024-03-08 16:36:10
           574 | pool10d303wup90j39mmvysf0lhr2xmr3mf38y5vs577nmlq6yy8n666 |  4889884591204 |     1.078 |           41 |    2115386 | 2024-05-21 18:51:42
-- <snip>

-- From the sample output above, we can see that pool
-- `pool1erufgazt3scqvjvsqv7ehayfscj93llzu3e6lknh2m6d5xcfjdr` is problematic
-- because it has not forged any blocks in the current epoch, the last block
-- forged time was more than 2 months ago and yet the pool has ~1% of stake.
```

Investigating problem pools further in psql:
```sql
-- Set and prepared statements may be further used to investigate the pool.
-- For examples below, toggle expanded output if desired with `\x`
-- Examples include:

-- Get general information about a pool
execute show_pool_info_fn ('$POOL_ID');

-- Show block history by epoch for a pool
execute show_pool_block_history_by_epoch_fn ('$POOL_ID');

-- See set statements available:
:show_<tab><tab>

-- See other prepared statements available:
execute show_<tab><tab>
```

Cardano-cli can also be queried for information about pools of interest:
```bash
POOLS=(
$POOL_ID1
$POOL_ID2
$POOL_ID3
...
)

# To dump each pools id, ~epoch stake in millions url and metadata on several lines
for i in "${POOLS[@]}"; do
  echo "Info for pool: $i"
  STAKE_SET=$(cardano-cli query stake-snapshot --stake-pool-id $i | jq -r '.pools | to_entries[0].value.stakeSet')
  STAKE_MLN=$(perl -E "say ($STAKE_SET / 1E12)")
  STAKE_RND=$(printf "%.2f" $STAKE_MLN)
  echo "Pool has epoch set stake of: $STAKE_RND million ADA"
  URL=$(cardano-cli query pool-state --stake-pool-id $i | jq -r '. | to_entries.[0].value.poolParams.metadata.url')
  echo "Metadata URL is: $URL"
  echo "Metadata is:"
  if RESP=$(curl -fkLs "$URL"); then
    jq -r <<< "$RESP"
  else
    jq -r <<< '{"MetadataFetchStatus":"failed"}'
  fi
  echo
done

# To summarize on one line pool id, ~epoch stake in millions, ticker and name or url
for i in "${POOLS[@]}"; do
  STAKE_SET=$(cardano-cli query stake-snapshot --stake-pool-id $i | jq -r '.pools | to_entries[0].value.stakeSet')
  STAKE_MLN=$(perl -E "say ($STAKE_SET / 1E12)")
  STAKE_RND=$(printf "%.2f" $STAKE_MLN)
  URL=$(cardano-cli query pool-state --stake-pool-id $i | jq -r '. | to_entries.[0].value.poolParams.metadata.url')
  if RESP=$(curl -fkLs "$URL"); then
    echo "Pool: $i    ~${STAKE_RND}M ADA stake    Ticker: $(printf "%-7s" "$(jq -r '.ticker' <<< "$RESP")")  Name: $(jq -r '.name' <<< "$RESP")"
  else
    echo "Pool: $i    ~${STAKE_RND}M ADA stake                     URL: $URL"
  fi
done
```

Finally, public cardano blockchain explorers offer quite a bit of info for pool
analysis, typically support most Cardano networks and can be consulted for
additional info.

Some example resources include (alphabetically sorted, non-exhaustive):
```
https://adapools.org/
https://beta.explorer.cardano.org
https://cardanoscan.io/
https://cexplorer.io/
https://explorer.cardano.org/
https://pooltool.io/
```
