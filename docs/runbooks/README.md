# Runbooks: role changes in Region A and Region B

Written to be typed by hand. Every step says what to run and what to look for. Region A names are used below
(`orcl`, `orcl_stb`, GG_A, prm1, stb1, observer obs-r1); for Region B use `orcl3`, `ORCL3_STB`, GG_B, prm3, stb3, obs-r2.

## Targets

These are targets chosen for this lab from its measured runs. In a real system they come from the business, per service.

| Event | RPO | RTO: database writable | RTO: Active-Active back |
|-------|-----|------------------------|-------------------------|
| Switchover (planned) | 0 | 2 min | 3 min |
| Primary lost, FSFO synchronized | 0 | 3 min | 5 min |
| Primary lost, FSFO **not** synchronized | a decision, see [03](03-manual-failover.md) | a decision | a decision |

Measured against these targets: [run 6](../../results/r6-run-summary.md), and Region B in [run 7](../../results/r7-region-b-summary.md). The failover times include the FSFO threshold of 90 s ([F20](../findings.md#f20)).

## Which runbook

| Situation | Runbook |
|-----------|---------|
| Planned maintenance on the primary | [01 Switchover](01-switchover.md) |
| Primary lost, observer and standby healthy: FSFO acts alone | [02 FSFO failover](02-fsfo-failover.md) |
| Primary lost and FSFO did not act | [03 Manual failover](03-manual-failover.md) |
| Old primary back after a failover | [04 Reinstate](04-reinstate.md) |
| Observer down, or `ORA-16820` | [05 Observer](05-observer.md) |
| After any role change: GoldenGate | [06 GoldenGate](06-goldengate.md) |
| After any failover: backups, keys, records | [07 After a failover](07-after-failover.md) |

## Connecting

```bash
ssh oracle@prm1
dgmgrl
```
```
DGMGRL> connect c##dgadmin@orcl
```
Type the password at the prompt (`DGADMIN_PASSWORD_A` in `lab.env`): on a command line it would show in `ps`.
From the host, `tests/dg.sh <host> <alias> "<command>"` does the same over stdin.
