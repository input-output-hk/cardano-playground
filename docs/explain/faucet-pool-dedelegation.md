# Faucet Pool De-delegation

The faucet may be used to delegate funds to community pools.  However when
pools are abandoned and no longer producing blocks, chain density will drop and
it makes sense to de-delegate the faucet delegated funds from the non-performing
pools.

## Pool Analysis
There are several ways to analyze whether pools are performing well.

One method would be to use dbsync and execute a `show_current_forging` prepared
statement as described in [debug-chain-quality.md](debug-chain-quality.md).

A more thorough analysis would be to use a specialized sql query to find valid
pools which are mature (registered for at least 3 epochs), delegated to, and
have not forged blocks for the current and past epoch.  The only argument
needed for this just recipe is the machine name of the dbsync to run the query
on.  In this example, we'll use preview network's dbsync machine:
```bash
just dbsync-pool-analyze preview1-dbsync-a-1
```

If this pool analysis sql query has not yet been run on the dbsync machine
before, the dbsync database will first need to have a stake address table added
which is derived from the faucet configuration.  To do this, an example for
preview again would be the following, where the `501` accounts value is
determined from the corresponding faucet config file's
`max_stake_key_index` value + 1.
```bash
# Prep dbsync for delegation analysis
# dbsync-prep ENV HOST ACCTS="501"
dbsync-prep preview preview1-dbsync-a-1 501
```

If the pool analysis sql query was run without first prepping the dbsync
database, you will receive an error of:
```bash
Query output:
LINE 159:       from faucet_stake_addr),
error: Recipe `dbsync-pool-analyze` failed with exit code 1
```

For more background information on faucet configuration, see
[faucet-setup.md](faucet-setup.md).

## Pool Analysis Results
The results of the `dbsync-pool-analyze` recipe above will output a large amount of information, which typically looks something like this:
```bash
Pushing pool analysis sql command on preview1-dbsync-a-1...
dbsync-pool-perf.sql

Executing pool analysis sql command on host preview1-dbsync-a-1...

Query output:
current_epoch                           | 603
current_epoch_stake                     | 479704314590689
pools_total                             | 355
pools_reg                               | 272
pools_unreg                             | 83
pools_reg_with_deleg                    | 245
pools_unreg_with_deleg                  | 5
pools_mature                            | 271
pools_immature                          | 84
pools_to_eval                           | 244
pools_over_2m                           | 62
pools_perf                              | 85
pools_not_perf                          | 159
pools_not_perf_outside_faucet           | 155
pools_not_perf_over_2m                  | 15
faucet_pool_total                       | 69
faucet_pool_active                      | 65
faucet_pool_not_perf                    | 4
faucet_pool_over_2m                     | 34
faucet_pool_to_dedelegate               | 4
pools_reg_with_deleg_deleg              | 474525381704825
pools_unreg_with_deleg_deleg            | 5178932885864
pools_to_eval_deleg                     | 473363919171706
pools_immature_deleg                    | 6340395418983
pools_perf_deleg                        | 366858782879439
pools_not_perf_deleg                    | 106505136292267
pools_not_perf_outside_faucet_deleg     | 63055383355749
pools_not_perf_over_2m_deleg            | 91821368233250
pools_over_2m_deleg                     | 418173168529672
faucet_pool_active_deleg                | 333710090279595
faucet_pool_not_perf_deleg              | 43449752936518
faucet_pool_over_2m_deleg               | 293714549293972
faucet_pool_to_dedelegate_deleg         | 43449752936518
faucet_pool_to_dedelegate_shift         | 4000000000000
pools_reg_with_deleg_deleg_pct          | 98.9
pools_unreg_with_deleg_deleg_pct        | 1.1
pools_to_eval_deleg_pct                 | 98.7
pools_immature_deleg_pct                | 1.3
pools_perf_deleg_pct                    | 76.5
pools_not_perf_deleg_pct                | 22.2
pools_not_perf_outside_faucet_deleg_pct | 13.1
pools_over_2m_deleg_pct                 | 87.2
pools_not_perf_over_2m_deleg_pct        | 19.1
faucet_pool_active_deleg_pct            | 69.6
faucet_pool_not_perf_deleg_pct          | 9.1
faucet_pool_over_2m_deleg_pct           | 61.2
faucet_pool_to_dedelegate_deleg_pct     | 9.1
faucet_pool_to_dedelegate_shift_pct     | 0.8
pools_not_perf_over_2m_json             | <json>
faucet_pool_over_2m_json                | <json>
faucet_pool_not_perf_json               | <json>
faucet_pool_summary_json                | <json>


{
  "faucet_pool_over_2m": {
    "$INDEX": { "$STAKE_ADDRESS": "$POOL_ID" },
    ...
  },
  "faucet_pool_not_perf": {
    "$INDEX": { "$STAKE_ADDRESS": "$POOL_ID" },
    ...
  },
  "faucet_to_dedelegate": {
    "$INDEX": { "$STAKE_ADDRESS": "$POOL_ID" },
    ...
  },
  "pools_not_perf_over_2m": {
    "$POOL_ID": { "$INDEX": "$STAKE_ADDRESS" },
    ...
  }
}

Faucet pools to de-delegate are:
{
  "$INDEX": { "$STAKE_ADDRESS": "$POOL_ID" },
  ...
}

The string of indexes of faucet pools to de-delegate from the JSON above are:
$DE_DEL_INDEX_1 $DE_DEL_INDEX_2 ... $DE_DEL_INDEX_N

The maximum percentage difference de-delegation of all these pools will make in chain density is: 0.8
```

There is a lot of information in the output above, and the sql analysis query
will automatically suggest de-delegation of any non-performing pools near the
bottom of the output.

Prior to de-delegating these non-performing pools, they can be investigated
further if desired with the cardano-postgres dbsync prepared statements, or by
verifying pool performance via community explorers.

## Pool De-delegation
Once satisfied that the list of non-performing pools to de-delegate is valid,
de-delegation can be performed by first starting a node for the desired
environment, if not already started, and waiting for the node to completely
synchronize:
```bash
just start-node "$ENV"
source <(just set-default-cardano-env "$ENV")
```

Then, run the de-delegation recipe and wait for the de-delegation script to
finish:
```bash
just dedelegate-pools "$ENV" "$DE_DEL_INDEX_1" "$DE_DEL_INDEX_2" ... "$DE_DEL_INDEX_N"
```

## De-delegation of Large Stake Pools
In some cardano networks where faucet pool delegations are 1M ADA, such as
preview and preprod, it may be desirable to de-delegate pools that are
performing well but have accumulated a large amount of stake and simply don't
need a faucet delegation contribution anymore.

Pools meeting this criteria can be found in the `faucet_pool_over_2m` json.

As part of deciding whether to de-delegate these large pools, weigh the fact
that if these pools are performing well, de-delegation will likely result in a
chain density drop as non-performing pools outside of faucet delegation then
receive a larger fraction of overall stake.
