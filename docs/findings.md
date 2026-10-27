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
