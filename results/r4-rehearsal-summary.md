# Run 4 — rehearsal before interview demos

Purpose: check that the lab still behaves as documented before interview demos. Same harness and
procedure as runs 2–3 (`tests/README.md`), scenario `dg-a` (prm1, stb1, obs-r1 + prm3).
Evidence: `results/raw/r4_*`, `results/timelines/r4_*`.

| # | Scenario | Data loss | New primary open read-write | App writes again (Region A) | Active-Active fully back | FSFO reinstate after VM start | Result |
|---|----------|-----------|-----------------------------|-----------------------------|--------------------------|-------------------------------|--------|
| 0 | Baseline | 0 / 0 | – | – | – | – | PASS |
| 1 | Switchover prm1 → stb1 | 0 | – | 29 s without writes (8 failed attempts) | 1 min 54 s | – | PASS |
| 2 | Switchback stb1 → prm1 | 0 | – | – | 1 min 57 s | – | PASS |
| 5 | **Power-off prm1**, FSFO → stb1 | 0 | +50 s | +78 s | **2 min 17 s**, automatic | 187 s | PASS |
| 4 | **Power-off stb1**, FSFO → prm1 | 0 | +43 s | +70 s | **1 min 32 s**, automatic | 137 s | PASS |

- **1,509 committed transactions, 0 lost**; the transaction committed in the very second of each power-off
  (#273 and #439) is on both databases. Region B: 0 errors.
- Cleanup in the documented order (workload stopped → both Replicats at EOF → STOP → drop → START): no abend.

## Found before the run: a GoldenGate capture pinned for 3 days

`DBA_CAPTURE.REQUIRED_CHECKPOINT_SCN` of `OGG$CAP_EXTA` was still 84170324 (the afternoon of the Stuck Archiver incident, an older
incarnation, three failovers ago), so the archived logs restored on 10-29 (`/u02/arch_restore`) could never be
released. `SEND EXTRACT EXTA, SHOWTRANS` showed one open transaction started minutes before the
Stuck Archiver incident with **0 items**; `GV$TRANSACTION` and `DBA_2PC_PENDING` had no such transaction.
`SEND EXTRACT EXTA, SKIPTRANS 1012467443.5.27.2391` (the `THREAD` option is rejected for per-PDB capture) →
`SHOWTRANS`: none; recovery checkpoint moved to the current time; a few minutes later the capture's required
checkpoint passed 84314083, so the restored logs are no longer needed.

Lesson: after an incident or a failover, check `SHOWTRANS` — a transaction the database no longer has can hold
the capture's restart point (and its archived logs) forever.
