# 03 Manual failover

The primary is gone and FSFO did not fail over. Find out why before you act: FSFO refusing can be the protection working
([run 5](../../results/r5-run-summary.md): target unsynchronized, a failover would have lost committed transactions).

## 1. Is the primary really gone?

Check from a second path (console, `virsh domstate`). A failover with a live primary gives you two primaries.

## 2. What state is the target in?

```
DGMGRL> connect c##dgadmin@orcl_stb
DGMGRL> show configuration;
DGMGRL> show fast_start failover;
```
```sql
select fs_failover_status, database_role, open_mode from v$database;
select name, value from v$dataguard_stats where name in ('transport lag', 'apply lag');
```

## 3. Decide

| State | Data loss | Action |
|-------|-----------|--------|
| `SYNCHRONIZED`, observer present, primary shut down | none | `failover to orcl_stb;` |
| Not ready for FSFO (unsynchronized, or no observer) and **the primary can come back** | none | **Prefer bringing the primary back**, then repair, then [01](01-switchover.md) |
| Not ready, and the primary cannot come back | possible: **the owner of the data decides, in writing** | below |

```
DGMGRL> disable fast_start failover force;     -- on the target, first
DGMGRL> failover to orcl_stb;                  -- complete: applies all redo received
```
`failover to orcl_stb immediate;` skips the remaining redo and usually loses data: only if the complete failover fails.

## 4. Afterwards

Record the SCN and the data lost (`standby_became_primary_scn`, last transactions in the client log).
Then [04](04-reinstate.md), [06](06-goldengate.md), [07](07-after-failover.md), and `enable fast_start failover` when
the configuration is `SUCCESS`.

**Not tested in this lab:** the forced path above. The rest comes from the broker documentation.
