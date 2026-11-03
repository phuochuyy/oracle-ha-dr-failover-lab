# Run 5 — re-run before an interview, with an incident in the middle

Same harness and procedure as runs 2–4 (`tests/README.md`), scenario `dg-a` (prm1, stb1, obs-r1 + prm3).
Evidence: `results/raw/r5_*` (rows of both sites, client logs, `verify.txt`), `results/timelines/r5_*`
(5-second samples, `.events`, `.reinstate.log`), incident log [`timelines/r5_t5_incident_stb1.log`](timelines/r5_t5_incident_stb1.log).

| # | Scenario | Data loss | New primary open read-write | App writes again (Region A) | Active-Active fully back | FSFO reinstate after VM start | Result |
|---|----------|-----------|-----------------------------|-----------------------------|--------------------------|-------------------------------|--------|
| 0 | Baseline | 0 / 0 | – | – | – | – | PASS |
| 1 | Switchover prm1 → stb1 | 0 | – | 23 s without writes | 1 min 42 s | – | PASS |
| 2 | Switchback stb1 → prm1 | 0 | – | 26 s without writes | 1 min 51 s | – | PASS |
| 5 | **Power-off prm1**, FSFO → stb1 | 0 | +44 s (PDB +57 s) | +58 s | **1 min 59 s**, automatic | not measured (incident below) | PASS |
| 4a | Power-off stb1 (primary) during the incident | 0 | **no failover** — FSFO refused, target unsynchronized, observer hung | 29 min outage, see below | after manual repair | – | correct refusal |
| 3 | Switchover prm1 → stb1 (to repeat 4) | 0 | – | 22 s without writes | 1 min 29 s | – | PASS |
| 4 | **Power-off stb1**, FSFO → prm1 | 0 | +58 s (failover done +43 s) | +67 s | **1 min 38 s**, automatic | 151 s | PASS |

- **6,629 committed transactions (1,730 Region A + 4,899 Region B), 0 lost** (`raw/r5_t8_final/verify.txt`);
  118 failed client attempts, all during role changes, none in doubt.
- Times: power-off/switchover command → alert log of the new primary (`Completed: ALTER DATABASE FAILOVER`,
  `ALTER DATABASE OPEN`, `ORCLPDB2 opened read write`) → first OK in the client log → first 5-second sample with
  EXTA, REPA, A2B, B2A and both clients OK again.
- Cleanup in the documented order (workload stopped → both Replicats at EOF → STOP → drop → START): no abend.

## Incident: the standby-turned-primary ran out of memory (18:01 → 18:29)

1. After scenario 5, stb1 was primary with GoldenGate (GG_A, DBFS) on a **5 GB VM** (4,481 MB usable, 1,380 MB in
   HugePages for the SGA). At 18:00:34 prm1 was started for its reinstate; at 18:01:10 Region A writes stopped.
   stb1 swapped (OS disk 900–1,500 reads/s), both vCPUs at 100 %, SSH and listener unresponsive; kernel:
   `task distsrvr / adminsrvr / AIService blocked for more than 122 seconds` (GoldenGate on DBFS).
2. Waited 5 min (no recovery), then **hard reset of the primary** (18:27:30): crash recovery, open read-write
   18:29:13, writes again 18:29:59, prm1 reinstated 18:29:55. Region A write outage: **28 min 49 s**. Region B: 0 errors.
3. Within minutes stb1 swapped again (5,017 / 5,017 MB by 18:33). The planned power-off of stb1 (18:37:36) caused
   **no failover**: `FS_FAILOVER_STATUS = UNSYNCHRONIZED`, observer not present. The observer had not reconnected
   since 18:29:55 (`Primary database cannot be reached` every second). In Zero Data Loss mode FSFO must refuse —
   a failover to an unsynchronized target can lose committed transactions.
4. Repair without data loss: start stb1 again (primary, crash recovery), wait for SYNCHRONIZED, **switchover to
   prm1** (7 GB), kill the hung observer process and start it again, broker SUCCESS 18:55.
5. Check after the repair: Region A rows from Region B were missing (3,118) — not lost, waiting in GG_B's trail:
   - `ogg_pathsync` (re-points B2A) had not started with GG_A on prm1: its start dependency was `pullup(GG_A)`,
     which only acts when the resource's TARGET is ONLINE — after the power-off and reboot of prm1 it was OFFLINE.
     **Fixed:** `pullup:always(xag.GG_A.goldengate)` on both clusters and in `lab/files/crs_pathsync.sh`.
   - Re-pointing B2A then timed out: GG_B's distribution service hung on the dead VIP of stb1 (`OGG-10401 No route
     to host`, `OGG-08517 operation for path B2A timed out`) → `systemctl restart ogg-ha` on prm3 → B2A running to
     `gg-a.rac`, backlog applied, check PASS (A 883 + B 3,939 rows on both sites).
6. Scenario 4 repeated afterwards with stb1 primary for about 11 minutes: PASS, B2A re-pointed by itself — the
   `pullup:always` fix worked.

## Lessons

- A standby must be sized to be the primary. stb1 (5 GB) carries the primary role only briefly; the host (23 GB RAM)
  cannot give it more while 4 VMs run. Limitation kept, written down; after a failover to stb1 switch back soon.
- FSFO refusing to fail over is the protection working — but nothing alerted that the observer was gone and the
  target unsynchronized. **Fixed:** the hourly health check now reports `CRIT fsfo` on the primary when the observer
  is absent or the status is not SYNCHRONIZED (backup lab, check 8).
- A CRS `pullup` dependency without `:always` silently does nothing after a crash.

## My mistakes in this run

- The reinstate timer of scenario 5 was not executable (`Permission denied`) — reinstate started 3 minutes late.
- My scenario runner piped its output through `tail` while the background timeline kept the pipe open: scenario 4
  waited 9 minutes with stb1 swapping. Runner fixed (timeline stopped by PID). Neither changed the data results.
