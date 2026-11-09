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

## F14

**Network encryption missing on the nodes that were off.** Native network encryption (AES256 + SHA256
REQUIRED) was set by hand on prm1 and stb1; prm2 and stb2 were off and kept no `sqlnet.ora`, so a client or
a service relocated to them would have connected in clear. A "do this before they start" note had not made it
happen. `sync_node` now runs `vm-nne.sh` on every Region A RAC node it starts: it installs the database-home
`sqlnet.ora` from `files/nne-sqlnet.ora` when it differs (old file kept) and adds
`ADMIN_RESTRICTIONS_LISTENER=ON`. prm1 unchanged; prm2 installed at boot, and a new connection through its
listener landed on `orcl2` encrypted and checksummed ([evidence](../results/maintenance/nne-at-boot.txt)).

## F15

**The RAC primary did not start at boot — and GoldenGate waited for it.** F9 made `vm_stop` shut the instance down
with `srvctl stop instance -stopoption immediate` (so block change tracking survives). `srvctl stop` sets the
resource TARGET to OFFLINE, and `ora.orcl.db` has `AUTO_START=restore`: at the next boot CRS restored exactly that,
so the database stayed down; the role-based service `ogg_a`, DBFS, the GoldenGate VIP and GG_A depend on it, and
`labctl` sat in its wait loops. A single `srvctl start instance` brought all of them up. Fix: `vm_start` now starts
the instance of every RAC node it boots (`db_start`, retried while CRS is still coming up, logged), and
`gg_heal` at the end of every scenario checks that `ogg_a` runs on the current primary (asks the broker which one),
that GG_B's admin/distribution/receiver servers are up, and starts any ABENDED Extract/Replicat — each action logged.
My mistake on the way: the first `gg_heal` also required `pmsrvr`, which is not enabled in these deployments; it
restarted a healthy GG_B and killed EXTB/REPB, which it then "healed" ([evidence](../results/maintenance/boot-selfheal.txt)).
Verified afterwards with cold boots of prm1 + prm3 and of stb1: `db_start` started the instance each time, and on prm1 everything above it came up, nothing by hand. Still unexplained: one earlier boot where CRS started the database itself and set `ogg_a` to target ONLINE, but never attempted to start it (crsd trace in the evidence file); `gg_heal` covers it if it comes back.

## F16

**Region B had never changed roles — and its standby could not become primary.** Every failover test ran in Region A;
Region B's standby was two days behind with transport off. Rolled forward from the primary (`RECOVER STANDBY DATABASE
FROM SERVICE`), protected again (FSFO Zero Data Loss), then a switchover: it **failed** with `ORA-16471` and left Region
B without a primary for about 2 minutes. The control file restored from the primary named online redo log directories
that exist only on prm3 (`/u02/redo2`, added there by a backup drill). Created on stb3, the broker completed the
switchover (31 s). GoldenGate followed by itself: GG_B moved to stb3 with its DBFS, the path from Region A re-pointed,
both directions replicated; switchback 16 s, rows both ways in 7–11 s ([evidence](../results/maintenance/region-b-switchover.txt)).
Lesson: after restoring a standby control file from the primary, check that every file path it names exists on the
standby — the database only notices at the role change. The power-off came later: [run 7](../results/r7-region-b-summary.md).

## F17

**Nothing stopped a scenario from starting on a nearly full host.** The rule "at least 12 GB free before starting" lived
only in a document, and I broke it myself twice by starting scenarios at 5 GB on my own judgement. The VM images are
thin-provisioned, so a full host pauses every VM with an I/O error (it happened once, when a standby pulled a redo gap).
First fix: `labctl.sh` refused to start a scenario below the limit, with an explicit override.
The lab owner later had the guard removed, so `labctl.sh` no longer checks free disk. The risk itself is unchanged: a full
host still pauses every VM. It is now handled by estimating redo and backup size before a write-heavy step and reading `df /`.

## F18

**No VM's clock was synchronised, and the one warning went unread.** The cluster verification utility had been writing `PRVG-13606` (chrony not synchronised) to the CRS alert log; no check of ours looked there. `chrony.conf` on every VM pointed at a public NTP pool, but the
VMs have no route to the internet: all sources at reach 0, `Leap status: Not synchronised`, clocks 0.6 s and 1.1 s behind the
host on the two nodes measured. It matters here more than usual: GoldenGate conflict resolution picks the latest timestamp,
and the timelines in this repository compare events across hosts. Fix: the KVM host serves NTP on the VM networks
([`host-ntp.sh`](../lab/files/host-ntp.sh), with `local stratum 10` so the VMs stay in step when the host is offline), and
`sync_node` points each VM at its default gateway ([`vm-ntp.sh`](../lab/files/vm-ntp.sh)), observers included. Result: all four
running VMs within 0.1 ms of their source and `cluvfy comp clocksync` passes
([evidence](../results/maintenance/vm-ntp.txt)). At the first sync the clocks were 0.2 to 0.8 s off, below chrony's 1 s step limit, so it slewed them: no clock step in the
`chronyd` journal on prm1.

## F19

**First look with Oracle's own checker.** `ORAchk` found what my own checks had not looked at: OCR and OLR backups too old, and OCR backups on the same disk group as the OCR. Fixed on both
clusters (`ocrconfig -backuploc +DATA`, manual backups). The other findings are accepted with a written reason, and ORAchk's database checks did not run in this setup
([details](../results/orachk/README.md)). My mistake on the way: the first runs purged ORAchk's previous report by its 14-day retention, so the earlier figures can no longer be checked.

## F20

**The FSFO threshold was too low for a RAC.** `validate fast_start failover`, never run before in this lab, warned `Fast-start failover threshold may be too low for RAC databases`. Oracle's MAA guide gives, for a
RAC primary, CSS misscount + reconfiguration + 30 s. With a misscount of 30 s the threshold went from 30 s to 90 s: a surviving node gets time to reconfigure before a failover. The price is real: a lost primary now
waits 60 s longer. Failover times of runs 1 to 5 were measured at 30 s and stay valid for that setting. The reconfiguration time in the formula was estimated, not measured. Region B has one instance and keeps 30 s.

## F21

**While the standby is down, Region A rows stop reaching Region B, and a check of Data Guard alone looks fine.** In run 6 the reconciliation after a power-off failed: 572 committed rows on Region A were missing on Region B. Nothing was lost: they
were on Region A and arrived within 40 s of restarting Extract with the standby back. The first explanation I wrote down was that the standby had been off for long, and it did not hold up. A [controlled test](../results/maintenance/r6-extract-standby-down.txt), with no failover:

| Standby down | Extract | One row A→B |
|--------------|---------|-------------|
| `HANDLEDLFAILOVER` on, no log switch | RUNNING, checkpoint frozen | not in 90 s |
| `HANDLEDLFAILOVER` on, after a log switch | RUNNING, checkpoint frozen | not in 90 s |
| `HANDLEDLFAILOVER` off, after a log switch | RUNNING, checkpoint moving | 5 s |

So the parameter is the cause. It does what it is for: Extract must not ship what a failover would lose, or Region B would be ahead of Region A. The price is a stopped replication while the standby is away, which the [runbook](runbooks/06-goldengate.md) now says.

**Not explained:** after a real failover Extract kept shipping for about 5 minutes (until 04:16:33), then abended with `OGG-06219` 18 s after the first log switch, and its automatic restarts ran out. The controlled test did not reproduce that abend. After a failover, check Extract explicitly: `gg_heal` only runs at the end of a `labctl` scenario.

**Second case, no failover:** while Database Vault was enabled on the RAC, the primary was restarted with the broker configuration disabled; EXTA abended twice with the same `OGG-06219` (capture `DISABLED`, `ORA-01013`) and started cleanly once the configuration was enabled again ([security lab, Database Vault log](https://github.com/phuochuyy/oracle-security-compliance-lab/blob/main/06-database-vault/results/region-a/enable-log.txt)). Both cases had `HANDLEDLFAILOVER` set and Data Guard protection not in its normal state; that is a lead to test, not yet a cause.

My mistake that made this visible: the client of the same test hung at exit, so the standby stayed off 25 minutes instead of a few.

## F22

**A Region B switchover succeeded, and replication from Region B stopped with nothing reporting it.** The first switchover after hardening took 25 s and the client wrote to the new primary 16 s after the start. Then the row comparison failed: 146 rows from Region B had not reached Region A. On stb3 the Distribution Service had failed to read its configuration from DBFS at startup (`OGG-12009`, `global.dat`, unchanged for days) and stayed alive with no port open. `INFO ALL` said `RUNNING`, the Service Manager left it alone, Data Guard said `SUCCESS`. No row was lost: they waited in the trail and arrived once the service was up.

Killing the process was enough: the Service Manager relaunched it and port 9102 was listening within 5 s. The Region B controller now does this itself when a service has been up for 60 s with its port closed ([`ogg-ha-controller.sh`](../lab/files/ogg-ha-controller.sh)). The three role changes after it passed without the watch acting, so the watch itself has only been proved by hand, not by a recurrence.

**Not explained:** why the read failed. DBFS had just been mounted on a database that had just opened, which is where I would look, but I did not prove it. Region A runs on XAG instead of this controller and has no such watch; it has not shown this failure.

Lesson: `INFO ALL` reports that a process exists, not that it works. Only comparing rows across the regions showed this. [Run 7](../results/r7-region-b-summary.md).

## F23

**An Application Continuity client crashed inside the Oracle client library when a RAC node died.** In [run 10](../results/r10-rac-node-summary.md) the surviving node took over in about 34 s and the database lost nothing, but the `bank_app` client process (python-oracledb 26.1, thick mode, Instant Client 23.26, Debian 13 with glibc 2.41, FAN events on) aborted with a glibc assertion about thread priorities. The plain client on the same host saw one error and carried on. Every transaction the crashed client had been told was committed is in the database; the one in flight is absent entirely.

**Not explained, seen once.** The client side of this lab is not a supported platform combination, so it may be specific to it. What it shows anyway: Application Continuity protects the database side of a request, and the application process still has to survive its own driver; a real deployment tests failover with the exact client stack it runs.

