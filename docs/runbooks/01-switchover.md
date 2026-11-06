# 01 Switchover (planned)

## Go / no-go

Stop if any check fails.

```
DGMGRL> show configuration;             -- SUCCESS
DGMGRL> show fast_start failover;       -- observer present, target valid
DGMGRL> validate database orcl_stb;     -- Ready for Switchover: Yes
```
```sql
select fs_failover_status from v$database;                  -- SYNCHRONIZED
select file_type, percent_space_used, percent_space_reclaimable from v$recovery_area_usage;   -- both sites
```
```bash
pgrep -x rman     # on both sites: no backup running
tests/gg.sh prm1 GG_A "info all"       # Extract and Replicat RUNNING
```

Size the target: stb1 is smaller than prm1 and cannot carry the primary role for long ([run 5](../../results/r5-run-summary.md)).
Plan the switchback before you start.

## Do

```
DGMGRL> switchover to orcl_stb;
```
Look for `Switchover succeeded, new primary is "orcl_stb"`. Clusterware restarts the old primary as a standby by itself.

## Verify

```
DGMGRL> show configuration;     -- connect through the new primary; SUCCESS, may take a minute
```
```bash
tests/gg.sh stb1 GG_A "info all"       # GG_A follows the primary
tests/gg_ping.sh stb1 prm3             # one row each way, exit 0
```

## If it fails

- `ORA-16471` (redo directory missing on the target): the database stays without a primary until fixed. Create the
  directory named in the alert log, run the switchover again ([F16](../findings.md#f16)).
- Never rerun blindly: read `show configuration` first, the switchover may have finished.
