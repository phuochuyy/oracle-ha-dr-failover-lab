# Run 7: Region B after hardening, first power-off of its primary

Region B: `orcl3` on prm3, `ORCL3_STB` on stb3, both 7 GB with HugePages, network encryption required, audit, profiles and redaction in place. FSFO threshold 30 s (single instance, no cluster reconfiguration to wait for). The client runs on prm1, because on prm3 it would die with the machine under test: one transaction per second to each region, a new connection each time ([`tests/r7_region_b.sh`](../tests/r7_region_b.sh)).

| Stage | Event | Role change | First commit on the new primary | Active-Active back | Rows checked | Result |
|-------|-------|-------------|---------------------------------|--------------------|--------------|--------|
| [t1](raw/r7_t1_switchover/) | Switchover prm3 → stb3 | [25 s](timelines/r7_t1_switchover.event.txt) | +16 s | **No: Region B rows stopped** | A 242, B 222; 146 B rows not in A | **FAIL** |
| [t1b](raw/r7_t1b_after_port_fix/) | Same state, after the fix | | | Yes | A 343, B 322, none missing | PASS |
| [t2](raw/r7_t2_switchback/) | Switchback stb3 → prm3 | [15 s](timelines/r7_t2_switchback.event.txt) | +15 s | [+80 s](timelines/r7_t2_switchback.log) | A 527, B 489, none missing | PASS |
| [t3](raw/r7_t3_failover_prm3/) | `virsh destroy prm3` | [+37 s, no data loss](timelines/r7_t3_failover_prm3.log) | +52 s | +118 s | A 856, B 610, none missing | PASS |
| reinstate | prm3 started again | [135 s to SUCCESS](timelines/r7_t3_reinstate.log), automatic | | | | |
| [t4](raw/r7_t4_switchback/) | Switchback stb3 → prm3 | [17 s](timelines/r7_t4_switchback.event.txt) | +15 s | [+82 s](timelines/r7_t4_switchback.log) | A 1,193, B 897, none missing | PASS |
| [final](raw/r7_t5_final/) | Client stopped | | | | | PASS |

Timeline of the power-off, from the standby's alert log, the observer log and the client log:

| Time | After power-off | What |
|------|-----------------|------|
| 18:53:49 | 0 | prm3 destroyed |
| 18:54:06 | +17 s | Observer: primary cannot be reached |
| 18:54:23 | +34 s | Threshold elapsed, zero data loss failover begins |
| 18:54:26 | +37 s | Failover complete, no data loss |
| 18:54:41 | +52 s | First client commit on stb3; 3 failed attempts (`ORA-12514`) before it |
| 18:55:47 | +118 s | Extract, Replicat and the path to Region A all running on stb3 |

## What this run found

**[F22](../docs/findings.md#f22): the switchover succeeded, and replication from Region B stopped with nothing reporting it.** On stb3 the Distribution Service could not read its configuration from DBFS right after the role change (`OGG-12009`, `global.dat`), stayed alive with no port open, and `INFO ALL` kept saying `RUNNING`. 146 rows waited in the trail: none lost, all arrived after the fix. Only the row comparison showed it. Fix: the Region B controller now kills such a process after 60 s and the Service Manager relaunches it. I do not know why the read failed: DBFS had just been mounted on a database that had just opened, but I did not prove this. It did not recur in the three role changes after the fix (the watch did not need to act), so the fix itself has been exercised only by hand.

**The former primary stays mounted after a role change.** The broker starts it in `MOUNTED`, not `READ ONLY WITH APPLY`. On the RAC, Clusterware opens it; Region B has no Clusterware. It is still a valid failover target, but reports on the standby would not work until it is opened ([`--open`](https://github.com/phuochuyy/oracle-backup-recovery-drills/blob/main/01-strategy/roll_forward_standby.sh)). Left as a manual step.

## Limits

Two virtual machines on one host, so "the site is down" means the VM was destroyed, not that a network or a storage array failed. The client opens a new connection for each transaction, so these numbers do not show what a pooled application would see; [Region A's Application Continuity test](app-continuity/README.md) does. Active-Active times come from samples every 5 to 7 s; each counts from the start of the event.
