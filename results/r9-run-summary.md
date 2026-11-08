# Run 9: stb1 at 7 GB, as primary under load

Run 6 found that stb1, the RAC standby, could not carry the primary role for long with 6 GB: swap full at 5,017 MB after 30 minutes. It now has 7 GB, the same as prm1. Same stages and client as run 6 ([`tests/r9.sh`](../tests/r9.sh)): two-way Active-Active client, plus the Application Continuity client pair.

| Stage | Event | Role change | Rows checked | Result |
|-------|-------|-------------|--------------|--------|
| [t0](raw/r9_t0_baseline/) | Baseline | | | PASS |
| [t1](raw/r9_t1_switchover/) | Switchover prm1 → stb1 | [97 s](app-continuity/r9_t1_switchover/event.txt) | A 124, B 175, none missing | PASS |
| soak | stb1 primary, 30 min, client writing | | | no hang, see below |
| [t2](raw/r9_t2_switchback/) | Switchback stb1 → prm1 | [63 s](app-continuity/r9_t2_switchback/event.txt) | A 1,971, B 2,055, none missing | PASS |
| [final](raw/r9_t6_final/) | Client stopped | | A 1,972, B 2,056, none missing | PASS |

Application Continuity: through the switchover, `bank_app` saw 0 errors in 339 transactions, `bank_plain` 1 error in 327; none lost or duplicated in either. Through the switchback, both 0 errors.

## Soak, stb1 as primary for 30 minutes ([samples](maintenance/r9-stb1-soak-7g.txt))

| | 6 GB, run 6 | 7 GB, run 9 |
|-|-------------|-------------|
| Samples answered | 58 of 58 | 58 of 58 |
| Lowest available memory | 781 MB | 746 MB |
| Highest swap used | 5,017 MB, all of it | 4,146 MB of 5,631 |

**Better, not solved.** With 7 GB the standby carried the primary and GoldenGate for 30 minutes without filling swap, and the client never stopped. It still swapped more than 4 GB: the swap partition grew with the RAM, and the memory the VM uses as primary did not shrink. The working rule stays: on this host, switch back to prm1 after a planned role change rather than run on stb1 for long. A real standby would have the primary's memory and nothing else on its host.
