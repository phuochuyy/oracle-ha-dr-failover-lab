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

## F9

**The standby's block change tracking was reset at every lab stop.** The standby alert log had no
`Shutting down ORACLE instance` line since the first days, and every start logged *"The change tracking
file is not usable … not closed cleanly the last time it was shutdown. Resetting change tracking file."*
`labctl.sh` stopped RAC nodes with `crsctl stop crs -f`, which aborted the instance. A level 1 offload
taken after such a restart could not use change tracking (`V$BACKUP_DATAFILE.USED_CHANGE_TRACKING = NO`,
78 % of the blocks read, 615 s against 760 s for the level 0). Fix: `vm_stop` now runs
`srvctl stop instance -db <db> -node <node> -stopoption immediate -force` first, then stops CRS.
Verified on stb1: `Shutting down ORACLE instance (immediate)`, and after the restart *"The change
tracking file is current"* — no reset. (The primary resets only at role changes, as expected.)

## F10

**The lab clean-up deleted archived logs a GoldenGate capture still needed.** `vm-cleanup.sh` (used by
`labctl.sh trim`) ran `DELETE ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-1'`, assuming RMAN keeps logs
a capture needs. For a per-PDB integrated capture it does not warn, and a capture's restart point can be
days old (a transaction left open by an incident held it — see the backup lab). The step is removed;
the FRA deletes logs under the deletion policy and orcl3 has its own housekeeping timer.

## F11

**After a credential rotation, nodes that were off locked two accounts.** A RAC node started outside
`labctl.sh` still had the old DBFS wallet (the new one waits in `files/pending/<node>/` and is installed
by `sync_node`): its `dbfs_client` failed 10 logons and locked `DBFS_USER` → DBFS returned I/O errors,
GoldenGate could not start, and CRS hung stopping it. The cluster wallet `CVUDB` also still held the old
`DBSNMP` password (and the standby cluster had none), which locked `DBSNMP`. Fix: unlocked both,
installed the pending wallets on prm2, stb2 and stb3, updated `CVUDB` on the primary cluster (its owner
is `oracle`) and created it on the standby cluster; a standby restart afterwards logged 0 `DBSNMP`
failures. Rule: after rotating a password, list every node and wallet that holds it, including nodes
that are switched off.

## F12

**The VMs' logs grew without limit, and every byte cost host disk.** The VM disks are sparse images on a
host with little free space, so a growing log inside a VM is host space until `fstrim` returns it — and
`fstrim.timer` was disabled. Two causes on the node running GoldenGate (prm1): (1) the Microservices
(ServiceManager, adminsrvr, distsrvr, recvsrvr) log every REST request to `authpriv`, including the full
JSON body of each 401 challenge — ~198 lines/min into `/var/log/secure`; (2) a daily, compressed rotation
for `secure` had been set up, but the backup copies left in `/etc/logrotate.d` (`*.bak.*`) are parsed too:
"duplicate log entry" → the real config was **skipped**, `secure` rotated weekly and uncompressed, one
rotated file 1.1 GB. Fix (`log_hygiene` in `labctl.sh sync_node`, so every node gets it at its next start):
GoldenGate lines to their own file `/var/log/ogg-http.log` (daily, 7 kept, max 100 MB, compressed), the
backups moved out of `/etc/logrotate.d`, uncompressed rotated logs compressed (1,124,924,239 → 34,801,235
bytes), `fstrim.timer` enabled. With `fstrim` on the three running VMs the host got back 1,283 MB
([evidence](../results/maintenance/log-hygiene.txt)). Lesson: never leave a backup of a config inside a
directory that is read as a whole (`*.d/`).

## F13

**Swap kept host space forever.** After F12 the host was still short of space. Each RAC node's image held
3.3–3.4 GB more than its file systems used — the size of its swap LV: a swap block, once written, stays
allocated in the sparse image, and `fstrim` does not touch swap. A one-off discard on stb2 freed 5.0 GB, and
10 minutes of running took 1.1 GB back — so the fix is `discard` on the swap entries in `/etc/fstab` (whole
area at `swapon`, freed pages while running and at shutdown), applied by `vm-swapdiscard.sh` from
`log_hygiene` (and run once on the observers, which `sync_node` skips). All 8 VMs: host free space 6.7 → 29.0 GB;
the boot-time discard checked on a VM where it was deferred ([evidence](../results/maintenance/swap-discard.txt)).
My mistake on the way: I discarded the first swap LV with `blkdiscard`, which also wiped its header — `swapon`
failed until `mkswap`. `swapon --discard` keeps the header.
