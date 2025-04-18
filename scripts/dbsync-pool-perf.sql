-- Set variables expected for this query to work are:
--   :table
--     Where :table is the final table to select all rows from.
--     This provides a convenient way select CTEs as well when exploring or debugging.
--
--   :lovelace
--     This used to be fixed to 2E12, but different networks now use different faucet delegation amount.
with
  current_epoch AS (
    select max(epoch_no) as current_epoch from block),

  last_epoch AS (
    select current_epoch - 1 as last_epoch from current_epoch),

  -- Required as a reference table to avoid subquery namespacing errors
  pool_table AS (
    select distinct pool_hash.id, hash_raw, view as pool_view, ticker_name from pool_hash
    left join off_chain_pool_data on pool_hash.id=off_chain_pool_data.pool_id),

  -- Total pools
  pools_total AS (
    select count(distinct view) as pools_total from pool_hash),

  -- Pools which are valid, registered and not retired
  pools_reg AS (
    select view from pool_update
      inner join pool_hash on pool_update.hash_id = pool_hash.id
      where registered_tx_id in (select max(registered_tx_id) from pool_update group by hash_id)
      and not exists (select * from pool_retire
        where pool_retire.hash_id = pool_update.hash_id
        and pool_retire.retiring_epoch <= (select max(epoch_no) from block))
      order by view),

  -- Pools which are not valid
  pools_unreg AS (
    select view from pool_hash
      where view not in (select view from pools_reg)),

  -- Pools which already have delegation as of the current epoch
  pools_reg_with_deleg AS (
    select pools_reg.view, sum(epoch_stake.amount) as lovelace from pools_reg
      inner join pool_hash on pools_reg.view = pool_hash.view
      inner join epoch_stake on pool_hash.id = epoch_stake.pool_id
      where epoch_stake.amount > 0
      and epoch_stake.epoch_no = (select * from current_epoch)
      group by pools_reg.view
      order by view),

  -- Pools not registered which have delegation as of the current epoch
  pools_unreg_with_deleg AS (
    select pools_unreg.view, sum(epoch_stake.amount) as lovelace from pools_unreg
      inner join pool_hash on pools_unreg.view = pool_hash.view
      inner join epoch_stake on pool_hash.id = epoch_stake.pool_id
      where epoch_stake.amount > 0
      and epoch_stake.epoch_no = (select * from current_epoch)
      group by pools_unreg.view
      order by view),

  -- Pools which are valid and have matured longer than 3 full epochs + 1 partial epoch
  -- 15 - 20 days for preprod, or 3 - 4 days for preview
  pools_mature AS (
    select pools_reg.view from pools_reg
      inner join pool_hash on pools_reg.view = pool_hash.view
      inner join pool_update on pool_hash.id = pool_update.hash_id
      where registered_tx_id in (select max(registered_tx_id) from pool_update group by hash_id)
      and active_epoch_no <= (select * from current_epoch) - 4
      order by view),

  -- Immature pools not meeting the above maturity constraint
  pools_immature AS (
      select view from pool_hash
      where view not in (select view from pools_mature)),

  -- Immature pools having delegation as of the current epoch
  pools_immature_deleg AS (
    select pools_immature.view, sum(epoch_stake.amount) as lovelace from pools_immature
      inner join pool_hash on pools_immature.view = pool_hash.view
      inner join epoch_stake on pool_hash.id = epoch_stake.pool_id
      where epoch_stake.amount > 0
      and epoch_stake.epoch_no = (select * from current_epoch)
      group by pools_immature.view
      order by view),

  -- Pool delegation sum for the current epoch
  pools_deleg_sum AS (
    select pool_hash.view, sum(amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch) group by pool_hash.id),

  -- Pools over :lovelace ADA
  pools_over_lt AS (
    select * from pools_deleg_sum where lovelace >= :lovelace),

  -- Pools over :lovelace ADA, delegation
  pools_over_lt_deleg AS (
    select pool_hash.view, sum (amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from pools_over_lt) group by pool_hash.id),

  -- Pools to check block production of considering constraints of: valid, mature, and have delegation
  pools_to_eval AS (
    select pools_reg_with_deleg.view from pools_reg_with_deleg
      inner join pools_mature on pools_reg_with_deleg.view = pools_mature.view
      order by view),

  -- Pools to eval, delegation
  pools_to_eval_deleg AS (
    select pool_hash.view, sum (amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from pools_to_eval) group by pool_hash.id),

  -- Forge count for eval pools in the current epoch
  pools_current_forged AS (
    select view, (select count(*)
      from block inner join slot_leader on block.slot_leader_id = slot_leader.id
      inner join pool_table on slot_leader.pool_hash_id = pool_table.id
      where pool_table.pool_view = view
      and block.epoch_no = (select * from current_epoch)
      group by block.epoch_no, pool_table.pool_view) as forged from pools_to_eval
      order by view),

  -- Forge count for eval pools in the last epoch
  pools_last_forged AS (
    select view, (select count(*)
      from block inner join slot_leader on block.slot_leader_id = slot_leader.id
      inner join pool_table on slot_leader.pool_hash_id = pool_table.id
      where pool_table.pool_view = view
      and block.epoch_no = (select * from last_epoch)
      group by block.epoch_no, pool_table.pool_view) as forged from pools_to_eval
      order by view),

  -- Pool forge history for current and last epoch
  pools_history AS (
    select eval.view, current.forged as current_forged, last.forged as last_forged
      from pools_to_eval eval
      inner join pools_current_forged current on current.view = eval.view
      inner join pools_last_forged last on last.view = eval.view
      order by view),

  -- Pools performant for the current and last epoch (at least 1 block forged)
  pools_perf AS (
    select view from pools_history where current_forged is not null or last_forged is not null
    order by view),

  -- Pools performing, delegation
  pools_perf_deleg AS (
    select pool_hash.view, sum (amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from pools_perf) group by pool_hash.id),

  -- Pools non-performant for the current and last epoch (no blocks forged)
  pools_not_perf AS (
    select view from pools_history where current_forged is null and last_forged is null
    order by view),

  -- Pools not performing, delegation
  pools_not_perf_deleg AS (
    select pool_hash.view, sum (amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from pools_not_perf) group by pool_hash.id),

  -- Table for active pool constraint registration debugging
  stake_reg_most_recent AS (
    select distinct on (addr_id) id, addr_id, cert_index, epoch_no, tx_id
    from stake_registration
    order by addr_id, tx_id desc, cert_index desc),

  -- Table for active pool constraint, deregistration
  stake_dereg_most_recent AS (
    select distinct on (addr_id) id, addr_id, cert_index, epoch_no, tx_id
    from stake_deregistration
    order by addr_id, tx_id desc, cert_index desc),

  -- Most recent faucet pool delegations per stake address
  -- This query uses the faucet_stake_addr table which is a custom added static table of: key as faucet_delegation_index, value as stake_address
  -- This query's second column is a function of the first column
  faucet_pool_last_active AS (
    select
      value as stake_addr,
      (select pool_hash.view from delegation
        inner join stake_address on delegation.addr_id = stake_address.id
        inner join pool_hash on delegation.pool_hash_id = pool_hash.id
        inner join stake_reg_most_recent on delegation.addr_id = stake_reg_most_recent.addr_id
        left join stake_dereg_most_recent on delegation.addr_id = stake_dereg_most_recent.addr_id
        where stake_address.view = value
        and (stake_dereg_most_recent.tx_id is null or stake_dereg_most_recent.tx_id < delegation.tx_id)
        order by delegation.tx_id desc limit 1) as view
      from faucet_stake_addr),

  -- Faucet active pool delegations without considering constraints
  faucet_pool_total AS (
    select * from faucet_pool_last_active
      where view is not null),

  -- Faucet active pool delegations considering constraints of: valid, mature, and have delegation
  faucet_pool_active AS (
    select * from faucet_pool_last_active
      where view is not null
      and view in (select view from pools_to_eval)),

  -- Faucet active pool delegations lovelace
  faucet_pool_active_deleg AS (
    select pool_hash.view, sum(amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from faucet_pool_active) group by pool_hash.id),

  -- Faucet pools non-performant for the current and last epoch (no blocks forged)
  faucet_pool_not_perf AS (
    select view from pools_history
    where current_forged is null
    and last_forged is null
    and view in (select view from faucet_pool_active)
    order by view),

  -- Faucet pools not performing, delegation
  faucet_pool_not_perf_deleg AS (
    select pool_hash.view, sum(amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from faucet_pool_not_perf) group by pool_hash.id),

  -- Faucet delegated pools with over :lovelace ADA stake delegated to them
  faucet_pool_over_lt AS (
    select pools_over_lt.view, pools_over_lt.lovelace from pools_over_lt
      inner join faucet_pool_active on pools_over_lt.view = faucet_pool_active.view),

  -- Faucet pools not performing and/or over :lovelace ADA stake to dedelegate
  faucet_pool_to_dedelegate AS (
    --select view from pools_history),
    select distinct view from (
      select view from faucet_pool_not_perf
      -- No longer automatically include pools over :lovelace for dedelegation as:
      --  a) some historical network faucets have used pool deleg amounts other than 1M, ex: sanchonet/private @ 10M pool deleg
      --  b) if large pools are performing well, de-delegating will drop chain density further which may not be desirable
      -- union
      -- select view from faucet_pool_over_lt
    ) as faucet_pool_to_dedelegate),

  -- Faucet pools not performing and/or over :lovelace ADA stake, delegation
  faucet_pool_to_dedelegate_deleg AS (
    select pool_hash.view, sum(amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from faucet_pool_to_dedelegate) group by pool_hash.id),

  -- Pools not performing and not delegated to by faucet
  pools_not_perf_outside_faucet AS (
    select view from pools_not_perf where view not in (select view from faucet_pool_active)),

  -- Pools not performing and not delegated to by faucet lovelace
  pools_not_perf_outside_faucet_deleg AS (
    select pool_hash.view, sum (amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from pools_not_perf_outside_faucet) group by pool_hash.id),

  -- Pools not performing with over :lovelace stake delegated to them
  pools_not_perf_over_lt AS (
    select pools_not_perf.view from pools_not_perf
      inner join pools_over_lt on pools_not_perf.view = pools_over_lt.view
      order by view),

  -- Pools not performing with over :lovelace stake delegated to them, with ticker name added for direct table query
  pools_not_perf_over_lt_meta AS (
    select pools_not_perf.view, ticker_name, lovelace from pools_not_perf
      inner join pools_over_lt on pools_not_perf.view = pools_over_lt.view
      left join pool_table on pools_not_perf.view = pool_table.pool_view
      order by lovelace desc),

  -- Pools not performing with over :lovelace stake delegated to them lovelace, delegation
  pools_not_perf_over_lt_deleg AS (
    select pool_hash.view, sum (amount) as lovelace from epoch_stake
      inner join pool_hash on epoch_stake.pool_id = pool_hash.id
      where epoch_no = (select * from current_epoch)
      and pool_hash.view in (select view from pools_not_perf_over_lt) group by pool_hash.id),

  -- Current epoch stake, matches cardano-cli activeStakeSet
  current_epoch_stake AS (
    select sum(amount) as current_epoch_stake from epoch_stake where epoch_no = (select * from current_epoch)),

  -- JSON for pools not performing over :lovelace ADA delegated
  pools_not_perf_over_lt_json AS (
    select json_object_agg(
      pools_not_perf_over_lt.view,
      jsonb_build_object(
        coalesce(faucet_stake_addr.key, 'notDelegated'),
        coalesce(faucet_stake_addr.value, 'notDelegated'),
        'ticker_name',
        pool_table.ticker_name
      )
    ) as pools_not_perf_over_lt_json
    from pools_not_perf_over_lt
      left join faucet_pool_total on pools_not_perf_over_lt.view = faucet_pool_total.view
      left join faucet_stake_addr on faucet_pool_total.stake_addr = faucet_stake_addr.value
      left join pool_table on pools_not_perf_over_lt.view = pool_table.pool_view),

  -- JSON for faucet delegated pools over :lovelace ADA delegated
  faucet_pool_over_lt_json AS (
    select json_object_agg(
      faucet_stake_addr.key,
      jsonb_build_object(
        faucet_stake_addr.value,
        faucet_pool_over_lt.view,
        'ticker_name',
        pool_table.ticker_name
      )
    ) as faucet_pool_over_lt_json
    from faucet_pool_over_lt
      inner join faucet_pool_total on faucet_pool_over_lt.view = faucet_pool_total.view
      inner join faucet_stake_addr on faucet_pool_total.stake_addr = faucet_stake_addr.value
      inner join pool_table on faucet_pool_over_lt.view = pool_table.pool_view),

  -- JSON for faucet delegated pools not performing
  faucet_pool_not_perf_json AS (
    select json_object_agg(
      faucet_stake_addr.key,
      jsonb_build_object(
        faucet_stake_addr.value,
        faucet_pool_not_perf.view,
        'ticker_name',
        pool_table.ticker_name
      )
    ) as faucet_pool_not_perf_json
  from faucet_pool_not_perf
    inner join faucet_pool_total on faucet_pool_not_perf.view = faucet_pool_total.view
    inner join faucet_stake_addr on faucet_pool_total.stake_addr = faucet_stake_addr.value
    inner join pool_table on faucet_pool_not_perf.view = pool_table.pool_view),

  -- JSON for faucet pools to dedelegate
  faucet_pool_to_dedelegate_json AS (
    select json_object_agg(
      faucet_stake_addr.key,
      jsonb_build_object(
        faucet_stake_addr.value,
        faucet_pool_to_dedelegate.view,
        'ticker_name',
        pool_table.ticker_name
      )
    ) as faucet_pool_to_dedelegate_json
  from faucet_pool_to_dedelegate
    inner join faucet_pool_total on faucet_pool_to_dedelegate.view = faucet_pool_total.view
    inner join faucet_stake_addr on faucet_pool_total.stake_addr = faucet_stake_addr.value
    inner join pool_table on faucet_pool_to_dedelegate.view = pool_table.pool_view),

  -- JSON faucet pool summary useful for dedelegation scripts
  faucet_pool_summary_json AS (
    select jsonb_build_object(
      'pools_not_perf_over_lt', (select * from pools_not_perf_over_lt_json),
      'faucet_pool_over_lt', (select * from faucet_pool_over_lt_json),
      'faucet_pool_not_perf', (select * from faucet_pool_not_perf_json),
      'faucet_to_dedelegate', (select * from faucet_pool_to_dedelegate_json)
    ) as faucet_pool_summary_json),

  -- Summary to help understand the state of delegation
  summary AS (
    select
      current_epoch,
      current_epoch_stake,
      pools_total,
      pools_reg,
      pools_unreg,
      pools_reg_with_deleg,
      pools_unreg_with_deleg,
      pools_mature,
      pools_immature,
      pools_to_eval,
      pools_over_lt,
      pools_perf,
      pools_not_perf,
      pools_not_perf_outside_faucet,
      pools_not_perf_over_lt,
      faucet_pool_total,
      faucet_pool_active,
      faucet_pool_not_perf,
      faucet_pool_over_lt,
      faucet_pool_to_dedelegate,

      pools_reg_with_deleg_deleg,
      pools_unreg_with_deleg_deleg,
      pools_to_eval_deleg,
      pools_immature_deleg,
      pools_perf_deleg,
      pools_not_perf_deleg,
      pools_not_perf_outside_faucet_deleg,
      pools_not_perf_over_lt_deleg,
      pools_over_lt_deleg,
      faucet_pool_active_deleg,
      faucet_pool_not_perf_deleg,
      faucet_pool_over_lt_deleg,
      faucet_pool_to_dedelegate_deleg,
      faucet_pool_to_dedelegate_shift,

      (select round(100 * pools_reg_with_deleg_deleg / current_epoch_stake, 1)) as pools_reg_with_deleg_deleg_pct,
      (select round(100 * pools_unreg_with_deleg_deleg / current_epoch_stake, 1)) as pools_unreg_with_deleg_deleg_pct,
      (select round(100 * pools_to_eval_deleg / current_epoch_stake, 1)) as pools_to_eval_deleg_pct,
      (select round(100 * pools_immature_deleg / current_epoch_stake, 1)) as pools_immature_deleg_pct,
      (select round(100 * pools_perf_deleg / current_epoch_stake, 1)) as pools_perf_deleg_pct,
      (select round(100 * pools_not_perf_deleg / current_epoch_stake, 1)) as pools_not_perf_deleg_pct,
      (select round(100 * pools_not_perf_outside_faucet_deleg / current_epoch_stake, 1)) as pools_not_perf_outside_faucet_deleg_pct,
      (select round(100 * pools_over_lt_deleg / current_epoch_stake, 1)) as pools_over_lt_deleg_pct,
      (select round(100 * pools_not_perf_over_lt_deleg / current_epoch_stake, 1)) as pools_not_perf_over_lt_deleg_pct,
      (select round(100 * faucet_pool_active_deleg / current_epoch_stake, 1)) as faucet_pool_active_deleg_pct,
      (select round(100 * faucet_pool_not_perf_deleg / current_epoch_stake, 1)) as faucet_pool_not_perf_deleg_pct,
      (select round(100 * faucet_pool_over_lt_deleg / current_epoch_stake, 1)) as faucet_pool_over_lt_deleg_pct,
      (select round(100 * faucet_pool_to_dedelegate_deleg / current_epoch_stake, 1)) as faucet_pool_to_dedelegate_deleg_pct,
      (select round(100 * faucet_pool_to_dedelegate_shift / current_epoch_stake, 1)) as faucet_pool_to_dedelegate_shift_pct,

      pools_not_perf_over_lt_json,
      faucet_pool_over_lt_json,
      faucet_pool_not_perf_json,
      faucet_pool_summary_json.*

    from current_epoch
      cross join current_epoch_stake
      cross join (select count(distinct view) as pools_total from pool_hash) as pools_total
      cross join (select count(distinct view) as pools_reg from pools_reg) as pools_reg
      cross join (select count(distinct view) as pools_unreg from pools_unreg) as pools_unreg
      cross join (select count(distinct view) as pools_reg_with_deleg from pools_reg_with_deleg) as pools_reg_with_deleg
      cross join (select count(distinct view) as pools_unreg_with_deleg from pools_unreg_with_deleg) as pools_unreg_with_deleg
      cross join (select count(distinct view) as pools_mature from pools_mature) as pools_mature
      cross join (select count(distinct view) as pools_immature from pools_immature) as pools_immature
      cross join (select count(distinct view) as pools_to_eval from pools_to_eval) as pools_to_eval
      cross join (select count(distinct view) as pools_over_lt from pools_over_lt) as pools_over_lt
      cross join (select count(distinct view) as pools_perf from pools_perf) as pools_perf
      cross join (select count(distinct view) as pools_not_perf from pools_not_perf) as pools_not_perf
      cross join (select count(distinct view) as pools_not_perf_outside_faucet from pools_not_perf_outside_faucet) as pools_not_perf_outside_faucet
      cross join (select count(distinct view) as pools_not_perf_over_lt from pools_not_perf_over_lt) as pools_not_perf_over_lt
      cross join (select count(distinct view) as faucet_pool_total from faucet_pool_total) as faucet_pool_total
      cross join (select count(distinct view) as faucet_pool_active from faucet_pool_active) as faucet_pool_active
      cross join (select count(distinct view) as faucet_pool_not_perf from faucet_pool_not_perf) as faucet_pool_not_perf
      cross join (select count(distinct view) as faucet_pool_over_lt from faucet_pool_over_lt) as faucet_pool_over_lt
      cross join (select count(distinct view) as faucet_pool_to_dedelegate from faucet_pool_to_dedelegate) as faucet_pool_to_dedelegate

      cross join (select sum(lovelace) as pools_reg_with_deleg_deleg from pools_reg_with_deleg) as pools_reg_with_deleg_deleg
      cross join (select sum(lovelace) as pools_unreg_with_deleg_deleg from pools_unreg_with_deleg) as pools_unreg_with_deleg_deleg
      cross join (select sum(lovelace) as pools_to_eval_deleg from pools_to_eval_deleg) as pools_to_eval_deleg
      cross join (select sum(lovelace) as pools_immature_deleg from pools_immature_deleg) as pools_immature_deleg
      cross join (select sum(lovelace) as pools_perf_deleg from pools_perf_deleg) as pools_perf_deleg
      cross join (select sum(lovelace) as pools_not_perf_deleg from pools_not_perf_deleg) as pools_not_perf_deleg
      cross join (select sum(lovelace) as pools_not_perf_outside_faucet_deleg from pools_not_perf_outside_faucet_deleg) as pools_not_perf_outside_faucet_deleg
      cross join (select sum(lovelace) as pools_not_perf_over_lt_deleg from pools_not_perf_over_lt_deleg) as pools_not_perf_over_lt_deleg
      cross join (select sum(lovelace) as pools_over_lt_deleg from pools_over_lt_deleg) as pools_over_lt_deleg
      cross join (select sum(lovelace) as faucet_pool_active_deleg from faucet_pool_active_deleg) as faucet_active_lt_deleg
      cross join (select sum(lovelace) as faucet_pool_not_perf_deleg from faucet_pool_not_perf_deleg) as faucet_not_perf_deleg
      cross join (select sum(lovelace) as faucet_pool_over_lt_deleg from faucet_pool_over_lt) as faucet_pool_over_lt_deleg
      cross join (select sum(lovelace) as faucet_pool_to_dedelegate_deleg from faucet_pool_to_dedelegate_deleg) as faucet_pool_to_dedelegate_deleg
      cross join (select count(distinct view) * 1E12 as faucet_pool_to_dedelegate_shift from faucet_pool_to_dedelegate) as faucet_pool_to_dedelegate_shift

      cross join pools_not_perf_over_lt_json
      cross join faucet_pool_over_lt_json
      cross join faucet_pool_not_perf_json
      cross join faucet_pool_to_dedelegate_json
      cross join faucet_pool_summary_json
    )

  select * from :table;

  -- Example useful tables to query from these CTEs:
  -- select * from summary;
  -- select * from pools_not_perf_over_lt_meta;
  -- select * from pool_table;
