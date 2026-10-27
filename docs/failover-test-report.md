# Failover test report

Running VMs: prm1, stb1 (Region A, one node per cluster), prm3 (Region B, GG_B), obs-r1 (observer).
Workload ran on prm3: site A through the role-independent address list
(`prm-scan`, `stb-scan`, service `ogg_a.rac`), site B locally. Times are host-local (+07:00).
Transaction counts are cumulative since the start of the run.

Timelines (5-second samples of DB role, GG_A process state, path targets, last client result):
[`results/timelines/`](../results/timelines/). Verification output:
[`results/verify-output.txt`](../results/verify-output.txt).

## T0 — Baseline

164 transactions, replicated both ways, sites identical. **PASS**

## T1 — Switchover `orcl` (prm1) → `orcl_stb` (stb1)

| Time | Event |
|------|-------|
| 15:54:05 | `switchover to orcl_stb` |
| 15:54:18 | XAG stops GG_A on prm1; B2A path killed |
| 15:54:35–55 | site A client: ORA-12514 (service moving) — 6 failed attempts, none committed |
| ~15:55:00 | site A writes succeed on stb1 |
| 15:55:11 | path sync re-points B2A to `gg-a-stb.rac` |
| 15:55:48 | EXTA + REPA RUNNING on stb1 |

440 transactions, 0 missing. **PASS**

## T2 — Switchback to `orcl`

App outage ~20 s (5 failed attempts), GG_A back on prm1 at 15:59:22. 669 transactions, 0 missing. **PASS**

## T3 — Power-off of the primary (`virsh destroy prm1`), FSFO

| Time | Event |
|------|-------|
| 16:03:20 | prm1 powered off |
| 16:04:03 | observer completes failover — stb1 PRIMARY (+43 s) |
| 16:04:24 | site A writes succeed on stb1 (+64 s) |
| — | **GG_A not started** (finding F1) |
| 16:22:59 | manual `agctl start goldengate GG_A` |
| 16:24:45 | EXTA restarts from checkpoint (SCN of 16:02:57, before the crash); REPA resumes trail `eb` |

2,598 transactions, 0 missing — including those committed just before power-off. **PASS (data); HA gap found.**

## T4 — Power-off of the primary stb1 → prm1 (with FAN callout)

| Time | Event | Since crash |
|------|-------|-------------|
| 16:35:42 | stb1 powered off | 0 |
| 16:36:29 | prm1 PRIMARY | +47 s |
| 16:36:38 | FAN `service=ogg_a.rac status=up` → callout | +56 s |
| 16:36:49 | site A writes succeed on prm1 | +67 s |
| 16:36:53 | callout: `xag.GG_A.goldengate` started | +71 s |
| 16:37:12 | B2A re-pointed to `gg-a.rac` | +90 s |
| 16:37:54 | EXTA + REPA RUNNING (after 60 s auto-restart delay → finding F2) | +2 min 12 s |

3,290 transactions, 0 missing, no manual action. **PASS**

## T5 — Power-off of the primary prm1 → stb1 (callout + tuned restart profile)

| Time | Event | Since crash |
|------|-------|-------------|
| 16:46:32 | prm1 powered off | 0 |
| 16:47:16 | stb1 PRIMARY | +44 s |
| 16:47:32 | FAN callout fires | +60 s |
| 16:47:37 | site A writes succeed on stb1 | +65 s |
| 16:47:53 | GG_A started | +81 s |
| 16:48:13 | EXTA + REPA RUNNING | +101 s |
| 16:48:26 | B2A re-pointed to `gg-a-stb.rac` — Active-Active complete | **+1 min 54 s** |

4,242 transactions, 0 missing, no manual action. **PASS**

## Reinstatement

After each power-off test the failed node was started again; FSFO auto-reinstate turned it into a
standby in ~3 min with no manual step. The lab was returned to `orcl` (prm1) primary by switchover.
