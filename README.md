# Oracle HA/DR Failover Lab — RAC + Data Guard FSFO + GoldenGate Active-Active

Self-built two-region Oracle high-availability / disaster-recovery lab on Linux KVM: each region protected by Data
Guard Fast-Start Failover (Zero Data Loss Mode), GoldenGate 23.26 Microservices replicating **Active-Active** between
the regions. The point is the **proof**: failover under live write load in both regions, every committed transaction
reconciled on both databases ([`tests/verify.py`](tests/verify.py)). Home lab on a 23 GB host, not production.

| Run | Events | Committed transactions | Lost | What it showed |
|-----|--------|------------------------|------|----------------|
| 1 | switchover, switchback, 3 power-offs of the primary | 4,242 (cumulative) | **0** | GoldenGate did not restart after an automatic failover → FAN callout ([F1](docs/findings.md#f1)); then back automatically in 1 min 54 s – 2 min 12 s |
| 2 | after TDE, network encryption, SYSDG-only observer | 1,862 | **0** | same procedure on the hardened databases ([details](docs/details.md#re-run-after-the-security-hardening-2026-10-29)) |
| 3 | after rotating the shared GoldenGate password | 2,535 | **0** | XAG keeps that password per cluster ([details](docs/details.md#run-3--after-the-password-rotation-2026-10-29-evening)) |
| 4 | rehearsal after the backup and security changes | 1,509 | **0** | [summary](results/r4-rehearsal-summary.md) |
| 5 | 2 switchovers, 2 power-offs, an out-of-memory primary in between | 6,629 | **0** | FSFO correctly refused to fail over to an unsynchronized target; fixed a CRS dependency of the path re-pointing ([summary](results/r5-run-summary.md)) |

- Findings F1–F14 with cause, fix and evidence: [`docs/findings.md`](docs/findings.md) · per-test report:
  [`docs/failover-test-report.md`](docs/failover-test-report.md) · architecture: [`docs/architecture.md`](docs/architecture.md).
- Full write-up (every run's table, snapshot standby drill, limitations): [`docs/details.md`](docs/details.md).
- Raw evidence: [`results/`](results/) (client logs, row dumps of both sites, 5-second timelines). Harness and the
  clean-up order for the test table: [`tests/README.md`](tests/README.md). Lab control: [`lab/labctl.sh`](lab/labctl.sh).
