# Interview notes — Oracle HA/DR Failover Lab

## The 2-minute story

I built a two-region Oracle 23ai lab on KVM: a 2-node RAC protected by a 2-node RAC standby, a
single-instance database with its own standby, Data Guard Fast-Start Failover in Zero Data Loss Mode
with an observer per region, and GoldenGate 23ai Microservices replicating Active-Active between the
regions.

The interesting part was not the install but proving it. I wrote a test harness that keeps writing
at both regions, powers off the primary with `virsh destroy`, and then checks every transaction the
client saw as committed on both databases. Result: **0 lost transactions out of 4,242**, the
database failed over in ~45 s and Active-Active was fully back in **1 min 54 s**.

The first power-off test failed in an instructive way: Data Guard failed over correctly, but
GoldenGate never started on the new primary. In the Clusterware traces I found that XAG relies on a
pullup from the role-based service, and after a Fast-Start Failover CRS starts that service without
pullups (`Opts 2102`, `NO_PULLUPS`) — a switchover works, a real failover does not. I fixed it with a
FAN server-side callout and repeated the power-off test twice to prove it.

## Likely questions

**What is the difference between MaxAvailability and MaxProtection? Why MaxAvailability?**
Both use SYNC transport. MaxProtection stops the primary if no standby can acknowledge; MaxAvailability
keeps running and falls back to unsynchronized until the standby is back. With FSFO in Zero Data Loss
Mode the observer only fails over when the configuration was synchronized, so I get zero data loss
without the primary stopping when the standby is down.

**How did you prove RPO = 0?** The client logs every transaction with `OK` only after COMMIT returned.
After each test I dump the rows of both databases and require every OK transaction to exist on both
([`tests/verify.py`](tests/verify.py)). Raw evidence is in [`results/`](results/).

**Why did GoldenGate not lose or duplicate data across the failover?** Three things:
`TRANSLOGOPTIONS HANDLEDLFAILOVER` (Extract never ships redo the standby has not received, so the
other region can never be ahead of the new primary), the deployment lives in DBFS inside the
protected database (checkpoints and trails fail over with the data), and Auto-CDR resolves any conflict
on replay.

**Why DBFS and not ACFS for the GoldenGate deployment?** DBFS is replicated by Data Guard with the same
zero-data-loss guarantee as the data. ACFS on a RAC is only local to the cluster; I would need ACFS
replication to the standby site as a second mechanism.

**What happens to the GoldenGate distribution paths when the primary moves?** The peer region still
points to the old address. A small script ([`ogg-path-sync.py`](lab/files/ogg-path-sync.py)) runs as a
CRS resource after GoldenGate starts and re-points both the outgoing path and the peer's incoming path.

**What made up the 1 min 54 s?** ~44 s FSFO (30 s threshold + failover), ~16 s until the role service
and the FAN callout, ~20 s GoldenGate start, ~20 s Extract/Replicat restart (I cut this from 60 s by
tuning the `HA` restart profile), ~13 s path re-pointing.

**Tell me about something that went wrong.** Besides XAG: my automation once enabled FSFO while the
primary was still `TRANSPORT-OFF` (the command was sent before the database opened and the broker kept
the old state), so the standby received nothing. And the standby's FRA filled up after heavy-redo tests
— the root cause was `fast_start_mttr_target = 0`, which left applied logs `IN-MEMORY` and never
reclaimable ([F8](docs/findings.md#f8)).

**What is a FAN callout?** An executable in `$GRID_HOME/racg/usrco` that Clusterware runs for every FAN
event (service/instance/node up or down). Mine reacts to `service=ogg_a status=up`.

**What would you do differently in production?** Test intra-cluster RAC node failover too (the lab only
has RAM for one node per cluster), put the observer in a third site, and use a recovery catalog and a
monitoring stack instead of scripts.

## 5-minute demo

```bash
./lab/labctl.sh dg-a                     # Region A with FSFO + GoldenGate
./tests/check.sh t0_baseline switchover   # empty baseline, starts the workload
./tests/timeline.sh results/timelines/demo.txt 600 &
virsh -c qemu:///system destroy prm1      # power-off the primary
# watch the timeline: stb1 PRIMARY (~45 s), GG_A RUNNING on stb1, B2A -> gg-a-stb.rac
./tests/check.sh demo                     # RESULT: PASS
```

## Limitations (say them before they are asked)

- One node per RAC cluster at a time (23 GB host), so "site loss" tests power off the whole primary
  cluster; RAC node failover inside a cluster is not tested here.
- Lab storage is virtual disks on one host — failover times are realistic, IO numbers are not.
