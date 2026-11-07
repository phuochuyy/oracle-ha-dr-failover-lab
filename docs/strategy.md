# Strategy: high availability and disaster recovery

The plan behind this lab, written as I would for a real system, with what was actually tested. Results: [details](details.md), [latest run](../results/r6-run-summary.md). Procedures: [runbooks](runbooks/README.md).

## Goal

A banking database that loses no committed transaction when a server or a site fails, comes back without a person having to act, and can be switched over for maintenance. RPO and RTO targets are in the [runbooks](runbooks/README.md#targets). They are lab targets: on a real system they come from the business, per service.

## Reference design

Closest to the Gold tier of Oracle's Maximum Availability Architecture: RAC for server failures, Active Data Guard for site failures, plus Fast-Start Failover so that nobody has to be awake. GoldenGate adds a second writable region. I do not claim a higher tier: it needs Exadata, and all of this runs on one host.

## Which failure is handled by what

| Failure | Mechanism | Data loss | Tested here |
|---------|-----------|-----------|-------------|
| Server process or session | Application Continuity on the service | none | Yes, [with limits](../results/app-continuity/README.md) |
| One RAC node | Surviving instance, service relocation | none | **Not as a power-off:** the lab normally runs one node per cluster for memory |
| Whole primary cluster | Fast-Start Failover, SYNC, Zero Data Loss Mode, automatic reinstate | none | Yes, every run |
| Planned maintenance | Broker switchover | none | Yes, every run |
| Region B primary | The same, on a single instance | none | Yes, [switchover and power-off](../results/r7-region-b-summary.md) |
| Region loss | GoldenGate Active-Active: the other region keeps writing, conflicts by latest timestamp | what had not been replicated | Partly: both regions written under failover, never a whole region lost |
| Human error, corruption | Flashback, RMAN, block checking | depends | [Backup lab](https://github.com/phuochuyy/oracle-backup-recovery-drills) |

## Choices, and what they cost

| Choice | Why | Cost |
|--------|-----|------|
| SYNC with MaxAvailability, not MaxProtection | No loss in normal running, and the primary survives a lost standby | Commit latency ([measured](https://github.com/phuochuyy/oracle-performance-tuning-lab/tree/main/03-cases/04-redo-io-commit-latency)) |
| FSFO threshold from Oracle's RAC formula | No failover while a surviving node is still reconfiguring ([F20](findings.md#f20)) | A lost primary waits longer |
| `HANDLEDLFAILOVER` on Extract | Region B can never be ahead of what a failover keeps | Region A to B stops while the standby is down ([F21](findings.md#f21)) |
| GoldenGate deployment on DBFS | Data Guard carries it to the new primary, with no separate replication | Replication depends on the database being open |
| Observer on the other region's network | It should not fail with the primary | One host here, so not truly independent |

## Operating it

- **Monitoring:** an hourly health check on each database reports role, FSFO state, observer, lag and capture position, and writes only when something changes.
- **Testing:** failure tests after every significant change, and a reconciliation of every committed transaction. On a real system: a switchover at least quarterly, run from the runbook by whoever is on call.
- **After a failover:** [checklist](runbooks/07-after-failover.md): backups, keys, encryption, records.

## Limits

One physical host, so a real site loss is not possible and timings are optimistic in some ways and pessimistic in others. The standby has less memory than the primary, so it should not carry the role for long. No release updates applied: no support contract. The observer has no backup instance.
