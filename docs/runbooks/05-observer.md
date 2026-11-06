# 05 Observer

Without an observer FSFO cannot fail over (`ORA-16820`, `ORA-16658`), and the primary keeps working. The health check
reports `CRIT fsfo` when it is absent.

```
DGMGRL> show observer;
DGMGRL> show fast_start failover;
```

Restart on the observer host:

```bash
ssh oracle@obs-r1
pgrep -a dgmgrl          # a hung process? kill it first (run 5)
```
Connect through the wallet, then `start observer in background`. If it stopped abnormally, name its existing file with the `file is` clause.

**Standby and observer lost together:** in Zero Data Loss Mode the primary cannot confirm that it may go on. It stalls, and with
`FastStartFailoverPmyShutdown = TRUE` it **shuts down** after the threshold. This protects against two primaries. Recovery:
restore the standby or the observer. If the primary must return before that, first confirm that no failover took place,
then `disable fast_start failover force;`.
