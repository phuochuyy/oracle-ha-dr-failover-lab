# Failover test harness

| File | Runs on | Purpose |
|------|---------|---------|
| `wl.sh` | prm3 | 1 tx/s per site, new connection per tx; logs `seq OK host phase` or `seq ERR code` |
| `check.sh <tag> [next-phase]` | host | stop workload, wait until both sites converge, dump rows, run `verify.py`, optionally restart workload |
| `verify.py` | host | every committed (OK) tx must exist on both DBs; both DBs identical; ERR rows allowed only as in-doubt |
| `timeline.sh <out> <secs>` | host | every 5 s: DB roles, GG_A node + process states, A2B/B2A status/target, last client result |
| `dg.sh`, `gg.sh` | host | run DGMGRL / AdminClient commands on a VM |
| `sql/create_txn.sql`, `sql/drop_txn.sql` | each PDB | test table with Auto-CDR, and its cleanup |

All scripts read credentials from `../lab.env`.

## Procedure

1. `labctl.sh dg-a`, then confirm `show configuration` = SUCCESS and `show fast_start failover`
   synchronized; confirm EXTA has `TRANLOGOPTIONS HANDLEDLFAILOVER`.
2. Run `sql/create_txn.sql` in ORCLPDB2 and in GGREPL. Copy `sql/role.sql` to `/home/oracle/` on prm1/stb1.
3. Start the workload: `./check.sh t0_baseline switchover` (verifies the empty baseline, then starts it).
4. For each scenario: start `timeline.sh`, trigger the event (`dg.sh … "switchover to …"` or
   `virsh destroy <primary>`), wait for convergence, then `./check.sh <tag> <next-phase>`.
5. After a power-off test: start the VM again and wait for FSFO auto-reinstate before the next test.

## Cleanup (order matters)

DDL is not replicated. Dropping the table while trail still contains changes for it makes the
Replicat abend with OGG-00199 when it re-reads from its checkpoint.

1. `touch /tmp/wl.stop` on prm3 and confirm no `wl.sh` process is left.
2. Wait until both Replicats show lag 0 and a read checkpoint later than the last workload row.
3. `STOP REPLICAT` on the site → run `sql/drop_txn.sql` → `START REPLICAT`. Repeat on the other site.
