# Run 10: one RAC node of the primary powered off

The failure the [strategy](../docs/strategy.md) listed as "not tested as a power-off": one node of the primary cluster dies while the other is up. The lab normally runs one node per cluster for memory; for this test prm1 and prm2 ran together, prm3 was shut down to make room. The services and GoldenGate were first moved to prm2, so that the node lost was the one carrying them; then `virsh destroy prm2` with the Application Continuity client pair writing from the host ([`tests/r10_rac_node.sh`](../tests/r10_rac_node.sh)).

| Time | After power-off | What | Source |
|------|-----------------|------|--------|
| 07:27:58 | 0 | prm2 destroyed | [event](app-continuity/r10_node_prm2/event.txt) |
| 07:28:25 | +27 s | CSS: network heartbeat from prm2 missing for 90 % of the 30 s timeout | [CRS alert log](maintenance/r10-crs-alert-prm1.txt) |
| 07:28:27 | +30 s | prm2 removed from the cluster, reconfiguration complete | same |
| 07:28:29 to :32 | +31 to +34 s | orcl1 recovers the dead instance's thread: 4.37 MB of redo | [alert log](maintenance/r10-instance-recovery-orcl1.txt) |
| by 07:28:37 | +39 s | service `bank_app` on orcl1 | [timeline](timelines/r10_node_prm2.log), 7 s samples |
| by 07:28:45 | +47 s | GoldenGate GG_A running on prm1 | same |
| 07:28:53 | +55 s | `bank_plain` client: its only error (`DPY-4011`), then it carried on | [client log](app-continuity/r10_node_prm2/bank_plain.log) |

**Fast-Start Failover did not fire, which is correct:** the database stayed open on prm1, the broker said `SUCCESS` throughout and after ([broker](maintenance/r10-broker-after.txt)). The FSFO threshold of 90 s ([F20](../docs/findings.md#f20)) leaves room for exactly this: 30 s of cluster timeout plus recovery, before the observer would act.

prm2 back through `labctl`: 119 s from start to orcl2 running. The services stayed on prm1, their preferred instance.

## The Application Continuity client crashed

`bank_plain`: 793 transactions, 1 error seen, 0 lost, 0 duplicated. `bank_app` did not finish: the Python process aborted inside the Oracle client library right after the power-off (`Fatal glibc error: tpp.c:83 (__pthread_tpp_change_priority): assertion failed`, then `ORA-24550` signal 6; [output](app-continuity/r10_node_prm2/bank_app.out)). Checked in the database: its 95 transactions reported OK are all there with both rows, and the one in flight is not there at all, so nothing was lost or half-written ([check](app-continuity/r10_node_prm2/bank_app-db-check.txt)). The same client had worked through a server process kill and through switchovers. This crash happened once and I have not reproduced or analysed it: python-oracledb 26.1 in thick mode with Instant Client 23.26 on Debian 13 (glibc 2.41), with FAN events on. See [F23](../docs/findings.md#f23).
