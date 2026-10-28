# Findings

Issues found while testing the lab under failure, with root cause, fix and verification.

## F1

**XAG does not start GoldenGate after a Fast-Start Failover (it does after a switchover).**

- **Symptom:** after `virsh destroy prm1`, the observer failed over to `orcl_stb` in ~43 s and
  service `ogg_a` came ONLINE on stb1, but `xag.GG_A.goldengate` stayed `Target=OFFLINE`.
  Extract/Replicat did not run on the new primary.
- **Root cause (crsd trace on stb1):** XAG's `--dataguard_autostart yes` relies on the
  `pullup:always(ora.orcl_stb.ogg_a.svc)` start dependency. The service start commands differ:

  | Event | Service start | Effect |
  |-------|---------------|--------|
  | Switchover | `Evaluating start of:ora.orcl_stb.ogg_a.svc ... Opts: 2` | dependents pulled up: dbfs_ogg → GG_A → ogg_pathsync |
  | FSFO failover | `... Opts: 2102`, DB label `ORA_STATE_HINT=NO_PULLUPS` | no pullups evaluated |

- **Fix:** FAN server-side callout [`lab/files/ogg-fan-callout.sh`](../lab/files/ogg-fan-callout.sh)
  in `$GRID_HOME/racg/usrco` on every RAC node. On `service=ogg_a… status=up` it runs
  `crsctl start resource xag.GG_A.goldengate` (CRS pulls the VIP, DBFS and nginx in as hard
  dependencies). It detaches with `setsid`, serialises duplicate events with `flock`, and logs to
  `/var/tmp/ogg_fan_callout.log`. The role-based service only runs on a PRIMARY, so the UP event is
  exactly "this node must run GoldenGate".
- **Verified:** tests 4 and 5 — callout fired ~10 s after the new primary opened, GoldenGate
  started with no human action.

## F2

**Abended processes waited 60 s before restart.** After a node is powered off, Extract/Replicat are
recorded as ABENDED; the `HA` managed-process profile restarted them only after
`autoRestart.delay = 60`. Changed to `autoStart.delay 10`, `autoRestart.delay 15` (retries and
window unchanged). The profile lives in the deployment on DBFS, so one change covers every node.
Recovery in test 5 was ~40 s faster than in test 4.

## F3

**Lab automation left the primary at `TRANSPORT-OFF` with FSFO enabled.** `labctl.sh dg-a` sent
`edit database orcl set state='TRANSPORT-ON'` seconds after boot, before the primary was open; the
command had no effect, yet the later `show configuration` returned a stale SUCCESS. The standby
received no redo while FSFO reported Enabled. Fix: retry until `show database` reports
`Intended State: TRANSPORT-ON`, and only enable `HANDLEDLFAILOVER` once the deployment is running.

## F4

**HugePages over-reservation on 5 GB standbys.** `vm.nr_hugepages = 1024` (2 GB) for an SGA of
1360 MB left 344 pages (~690 MB) permanently free and unusable while the VM swapped. Resized to 690
pages (SGA + margin).

## F5 (open)

**GoldenGate ServiceManager on prm3 sometimes starts only `adminsrvr` after boot** —
`deploymentConfiguration.dat` says distsrvr/recvsrvr `running/enabled` but they are never launched.
Workaround: `systemctl restart ogg-ha` (clean stop/unmount/start). Root cause not yet found.

## F6

**Test cleanup can abend Replicat (OGG-00199).** DDL is not replicated; dropping the test table
while trail still held changes for it made REPA/REPB abend on restart (they re-read from their
checkpoint and must resolve the table). Safe order, documented in
[`tests/README.md`](../tests/README.md): stop workload → let both Replicats read past the last
change → STOP Replicat → drop → START.

## F7

**Switching lab scenarios left Extract STOPPED.** `labctl.sh` toggles `HANDLEDLFAILOVER` by sending
`STOP EXTRACT` and `START EXTRACT` in one AdminClient script. `STOP` returns before the Extract has
actually stopped, so the `START` was ignored and EXTA stayed down (log: `OGG-06219 Unable to extract
data from the Logmining server` while stopping, then `stopped normally`, no restart). Fix: poll
`INFO EXTRACT` until `Status STOPPED`, then send `START`. Verified by toggling the parameter on and
off — EXTA restarted both times.

## F8

**The FRA did not reclaim applied archived logs; the 10 GB standby FRA filled up twice.** With
`ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY` on both orcl3 and its standby,
`V$RECOVERY_AREA_USAGE` still showed ~0–3 % of archived logs reclaimable, while `RMAN DELETE ARCHIVELOG
ALL` deleted the same logs without warnings (no guaranteed restore point, GoldenGate capture not
holding them). After heavy-redo performance tests the standby hit `ORA-19809`, redo transport stopped
and FSFO became unsynchronized — a failover in that window would not have been zero data loss.
**Root cause (found later):** `fast_start_mttr_target = 0` (and `log_checkpoint_interval = 0`) on
the standby. With real-time apply the redo is applied in memory, but without incremental
checkpoints media recovery almost never checkpoints the standby datafiles, so the logs stay
`V$ARCHIVED_LOG.APPLIED = 'IN-MEMORY'` (19 logs / 3.7 GB with apply lag 0 s). RMAN and the FRA only
treat a log as applied after that checkpoint → not reclaimable. Setting
`fast_start_mttr_target = 300` turned all 19 into `APPLIED = YES` within 90 s and the next
housekeeping run deleted them (stb3 FRA 5.9 → 2.3 GB). Set on the primary as well, so a future
standby after a switchover behaves the same.
Fix: [`arch-housekeeping.sh`](../lab/files/arch-housekeeping.sh) + systemd timer every 10 minutes on
prm3 and stb3 (installed by `labctl.sh` `sync_node`). It only runs the policy-respecting RMAN delete,
so logs not yet applied on the standby or still needed by GoldenGate stay. Log: `~oracle/arch-housekeeping.log`.
First runs: prm3 FRA 10.7 → 8.0 GB, stb3 → 2.2 GB.
