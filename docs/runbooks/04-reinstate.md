# 04 Reinstate the old primary

With `FastStartFailoverAutoReinstate = TRUE` this is automatic once the old primary starts.

```bash
virsh -c qemu:///system start prm1       # Region A primary node; prm2, stb2, stb3 only through labctl.sh
```
```
DGMGRL> show configuration;     -- from the new primary, repeat until SUCCESS
```

Not automatic, or it failed:

```
SQL> startup mount                       -- on the old primary
DGMGRL> reinstate database orcl;         -- connected to the new primary
```
It needs Flashback Database on the old primary before the failover, and enough flashback logs. If not: re-create it
as a standby. Also re-create it after `ORA-752` or `ORA-600 [3020]`: do not reinstate.

After a reinstate, check the Data Guard state, then switch back if the new primary is the smaller node:
[01 Switchover](01-switchover.md).
