# Oracle HA/DR Failover Lab — RAC + Data Guard FSFO + GoldenGate Active-Active

Self-built two-region Oracle high-availability / disaster-recovery lab on Linux KVM:
two regions, each protected by Data Guard Fast-Start Failover, with GoldenGate 23ai Microservices
replicating **Active-Active** between the regions. The point of the project is not the install
but the **proof**: failover tested under live bidirectional write load, every committed
transaction reconciled on both sites.

> Home lab, not production. Built and operated end-to-end by one person on a 23 GB host.

## Results

Continuous workload: 1 transaction/second written at **each** region; every write opens a new
connection (like an application with retry). After each test, every transaction the client saw
as committed is checked on **both** databases ([`tests/verify.py`](tests/verify.py)).

| # | Scenario | Data loss | App write outage (Region A) | Active-Active fully back | Result |
|---|----------|-----------|-----------------------------|--------------------------|--------|
| 0 | Baseline, both regions writing | 0 | – | – | PASS |
| 1 | Broker switchover prm1 → stb1 | 0 | ~25 s | ~1 min 45 s | PASS |
| 2 | Switchback stb1 → prm1 | 0 | ~20 s | ~1 min 30 s | PASS |
| 3 | **Power-off primary** (`virsh destroy prm1`), FSFO | 0 | ~64 s | GG did **not** restart → [finding F1](docs/findings.md#f1) | PASS (data) |
| 4 | Power-off primary stb1 → prm1, after fix | 0 | ~67 s | 2 min 12 s, fully automatic | PASS |
| 5 | **Power-off primary prm1 → stb1, after fix** | 0 | ~65 s | **1 min 54 s, fully automatic** | PASS |

- **RPO = 0** across 4,242 committed transactions (cumulative), including transactions committed
  seconds before the power-off — FSFO Zero Data Loss Mode + Extract `HANDLEDLFAILOVER`.
- Region B (the other side of Active-Active) kept writing through every test with **zero errors**;
  its changes were queued in trail and applied once GoldenGate came back on the new primary.
- Raw evidence: [`results/`](results/) (client logs, row dumps of both DBs, 5-second timelines).
  Details per test: [`docs/failover-test-report.md`](docs/failover-test-report.md).

## Architecture

```mermaid
flowchart LR
  subgraph A["Region A"]
    direction TB
    P["RAC orcl<br/>prm1 · prm2"] -- "SYNC redo<br/>MaxAvailability" --> S["RAC standby orcl_stb<br/>stb1 · stb2 (ADG)"]
    O1(["Observer obs-r1<br/>FSFO 30 s"]) -.-> P & S
    GA["GG_A (XAG + DBFS + VIP)<br/>runs on current primary"]
  end
  subgraph B["Region B"]
    direction TB
    P3["orcl3<br/>prm3"] -- "SYNC redo" --> S3["ORCL3_STB<br/>stb3"]
    O2(["Observer obs-r2"]) -.-> P3 & S3
    GB["GG_B (systemd controller + DBFS)"]
  end
  GA -- "A2B path (trail ea)" --> GB
  GB -- "B2A path (trail eb)" --> GA
```

| Component | Implementation |
|-----------|----------------|
| Database | Oracle 23ai (23.26) on Oracle Linux 9.8, CDB/PDB; GI 23ai, ASM |
| Region A HA | 2-node RAC → 2-node RAC standby, Broker, MaxAvailability, FSFO Zero Data Loss, auto-reinstate |
| Region B HA | Single instance → physical standby, Broker, FSFO (observer obs-r2) |
| Replication | GoldenGate 23.26.1 MA, Integrated Extract + Parallel Replicat, Auto-CDR, loop prevention via tag `00` |
| GG HA on RAC | XAG `--dataguard_autostart`, deployment on **DBFS** (Data Guard carries it to the standby), app VIP, nginx reverse proxy |
| GG HA without GI | [`ogg-ha-controller.sh`](lab/files/ogg-ha-controller.sh): systemd loop that runs GG only when the local DB is PRIMARY |
| Path retarget | [`ogg-path-sync.py`](lab/files/ogg-path-sync.py): after a role change, re-points both distribution paths to the live peer |
| Failover gap fix | [`ogg-fan-callout.sh`](lab/files/ogg-fan-callout.sh): FAN callout that starts GG after FSFO failover |

More: [`docs/architecture.md`](docs/architecture.md).

## Problems found and fixed

Testing under failure found issues a happy-path install never shows. Full write-ups in
[`docs/findings.md`](docs/findings.md).

1. **XAG does not start GoldenGate after FSFO failover** (only after switchover): on failover CRS
   starts the role-based service without pullups (`Opts 2102`, `ORA_STATE_HINT=NO_PULLUPS`).
   Fixed with a FAN server-side callout; verified with two further power-off tests.
2. GoldenGate `HA` restart profile waited 60 s before restarting abended processes → tuned to 15 s,
   cutting ~40 s from recovery.
3. Lab automation enabled FSFO while the primary was still `TRANSPORT-OFF` (command sent before the
   DB opened) → now retries until the broker confirms the state.
4. Over-reserved HugePages (2 GB for a 1.36 GB SGA) on 5 GB standby VMs → resized, freeing ~690 MB.

## Repository layout

```
lab/        labctl.sh (scenario control) + HA scripts deployed to the VMs
tests/      workload, verification, timeline recorder, helpers   → tests/README.md
results/    raw evidence of the test run
docs/       architecture, test report, findings
```

Credentials are never stored in the repo: copy `lab.env.example` to `lab.env` (git-ignored).

## Limitations

- Host RAM (23 GB) allows one node per RAC cluster at a time, so the failure tests powered off the
  only running node of the primary cluster (a full-site loss). Intra-cluster RAC node failover is
  not covered here.
- Standby VMs at 5 GB swap heavily (~4 GB) when they take over as primary with GoldenGate.
