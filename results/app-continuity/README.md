# What the application sees during a role change

Two services on the same pluggable database, two clients side by side through the same event ([`tests/tac_compare.sh`](../../tests/tac_compare.sh)):
`bank_app` has Transparent Application Continuity and Transaction Guard (`-failovertype AUTO -commit_outcome TRUE`); `bank_plain` has neither. Each transaction is insert, 0.3 s wait, insert, commit, so an outage is likely to hit one in flight. The table has no unique key, so a replay that ran twice would show as extra rows. The client compares what it was told with what is in the database.

| Event | `bank_app`: errors seen | `bank_plain`: errors seen | Lost / duplicated | Evidence |
|-------|-------------------------|---------------------------|-------------------|----------|
| Server process killed (`kill -9`) | **0**, slowest transaction 477 ms | **1** (`DPY-4011`) | 0 / 0 | [try 4](try4-kill-server-process/) |
| Switchover, 2 runs | 0 | 0 | 0 / 0 | [t1](r6_t1_switchover/), [t2](r6_t2_switchback/) |
| Power-off, no client timeout | client hung over 9 minutes, killed | same | not known: no summary | [try 2](try2-poweroff-prm1-no-timeout/) |
| Power-off, `SQLNET.RECV_TIMEOUT=30`, 3 runs | 1 per run, after about 60 s | 1 per run, after about 60 s | 0 / 0 | [try 3](try3-poweroff-stb1-recv-timeout/), [t3](r6_t3_failover_prm1/), [t5](r6_t5_failover_stb1/) |

## What this means

- **TAC works here for a failure the client can see**, such as a dead server process: the application got no error and the transaction was replayed once.
- **It did not help when the whole cluster lost power.** No node is left to move the VIP or send a reset, so the client just waits. Without a limit it waited over 9 minutes. `RECV_TIMEOUT` bounds the wait, but that timeout comes back as an error the client does not replay. A real application must still retry. Lower `tcp_retries2` or FAN events from the surviving cluster might change this; not tested.
- A switchover showed no errors on either service, so it does not separate them. New requests just waited for the new primary.
- `RECV_TIMEOUT` has a cost: a statement silent for longer fails, so it must exceed the longest expected call.

Limits: one Python client (python-oracledb, thick mode) with one session, no real application. TAC is included with RAC and Active Data Guard licences.
