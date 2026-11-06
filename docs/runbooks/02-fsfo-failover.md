# 02 FSFO failover (automatic)

The observer fails over by itself once the primary has been unreachable for `FastStartFailoverThreshold`. **Do not
start the old primary until you know what happened**: FSFO reinstates it when it comes back.

## Confirm

```
DGMGRL> connect c##dgadmin@orcl_stb
DGMGRL> show configuration;
```
Expect `orcl_stb - Primary database`, `orcl - (*) Physical standby database (disabled)`, `ORA-16661: The standby
database must be reinstated`, status WARNING. That WARNING is expected until the reinstate.

```sql
select database_role, open_mode, fs_failover_status from v$database;     -- PRIMARY, READ WRITE, REINSTATE REQUIRED
```
```bash
tests/gg.sh stb1 GG_A "info all"       # GG_A is started by the FAN callout, F1
```

## FSFO did not act?

Go to [03](03-manual-failover.md). Do not wait past your target.

## Do not leave the old primary down

While it is down, Region A rows stop reaching Region B ([F21](../findings.md#f21)). Start it as soon as you know why it failed.

## Then

[04 Reinstate](04-reinstate.md), [06 GoldenGate](06-goldengate.md), [07 After a failover](07-after-failover.md).
