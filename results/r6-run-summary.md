# Run 6: the current configuration, with Oracle's checks applied

Same harness and procedure as runs 2 to 5 ([`tests/README.md`](../tests/README.md)), scenario `dg-a`. Differences from run 5: VM clocks synchronised ([F18](../docs/findings.md#f18)), **FSFO threshold 90 s instead of 30 s** ([F20](../docs/findings.md#f20)), stb1 6 GB instead of 5 GB, prm3 6 GB instead of 7 GB, Region B hardened (network encryption), `DB_BLOCK_CHECKING=MEDIUM`, an Application Continuity client next to the workload.

Evidence: `results/raw/r6_*` (`verify.txt`, rows of both sites, client logs), `results/timelines/r6_*`, [`app-continuity/`](app-continuity/README.md).

| # | Event | New primary open | Active-Active back | Reinstate after VM start | Reconciliation |
|---|-------|------------------|--------------------|--------------------------|----------------|
| t1 | Switchover prm1 → stb1 | broker done +71 s | +77 s | – | PASS |
| t2 | Switchback stb1 → prm1 | broker done +76 s | +87 s | – | PASS |
| t3 | **Power-off prm1**, FSFO → stb1 | failover done +104 s, ORCLPDB2 writable +122 s | +165 s, automatic | 211 s | PASS |
| t5 | **Power-off stb1**, FSFO → prm1 | failover done +99 s, ORCLPDB2 writable +115 s | +154 s, automatic, then **stopped**, see below | 141 s | **FAIL**, then PASS |
| t6 | Final | – | – | – | **PASS**: 4,281 + 4,826 committed rows, 0 missing, both sites identical ([verify](raw/r6_t6_final/verify.txt)) |

Times: command or power-off → alert log of the new primary (`Completed: ALTER DATABASE FAILOVER`, `ORCLPDB2 opened read write`) → first 5-second sample with EXTA, REPA, A2B, B2A and the Region A client all OK. All within the [targets](../docs/runbooks/README.md).

Failover is about a minute slower than in earlier runs, by design: the threshold went from 30 s to 90 s.

## The failed reconciliation

After t5, 572 committed rows of Region A were missing on Region B ([verify](raw/r6_t5_failover_stb1/verify.txt)). They were not lost: Extract had stopped shipping with the standby down, and they arrived once it ran again. Cause and controlled test: [F21](../docs/findings.md#f21). The abend itself is not explained.

## stb1 as primary for 30 minutes

Run 5 hung stb1 at 5 GB within minutes. At 6 GB, under the workload and with prm1 reinstating: 58 of 58 samples answered, no new client errors, lowest available memory 781 MB ([samples](maintenance/r6-stb1-soak.txt)). But swap reached 5,017 of 5,017 MB, so the margin is thin: the rule stays "switch back soon". A backup ran on prm1 for the first 11 minutes of this period, on another VM sharing the host.

## My mistakes in this run

- The test client hung at exit (`bank_app`, 13 minutes after writing its result), and the stage script waited for it. This delayed the standby's restart and is why F21 showed up at all. Fixed: the client exits directly.
- I wrote down "the standby was off too long" as the cause before testing it. The controlled test showed otherwise.
- I stopped the backup timers for the test, but `systemctl stop` does not survive a reboot: after the power-off of prm1 its level 1 ran during the test. Harmless, and it shows the job follows the standby role, but my note said no backup was running.
