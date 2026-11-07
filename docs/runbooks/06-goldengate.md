# 06 GoldenGate after a role change

GG_A runs on the current primary of Region A. Run from the host, with `<p>` the primary's node.

```bash
tests/gg.sh <p> GG_A "info all"                       # Extract, Replicat RUNNING; pmsrvr STOPPED is normal
tests/gg.sh <p> GG_A "info distpath all"              # A2B running
tests/gg.sh prm3 GG_B "info all" "info distpath all"  # B2A running
tests/gg_ping.sh <p> prm3                             # one row each way
```

| Symptom | Cause | Action |
|---------|-------|--------|
| GG_A not up after FSFO | FAN callout did not fire | `agctl status goldengate GG_A`, `/var/tmp/ogg_fan_callout.log` on the new primary |
| `EXTA` ABENDED | capture lost the database connection | `tests/gg.sh <p> GG_A "start extract exta"` |
| Region A rows stop reaching Region B, primary keeps writing, standby down | `HANDLEDLFAILOVER` holds Extract at what the standby has received ([F21](../findings.md#f21)) | Bring the standby back. Then, if `EXTA` is ABENDED, `start extract exta` |
| Standby stays down for long and Region B must catch up | same | Decide: `labctl.sh` `dg_isolate` removes the parameter. Region B can then get ahead of what a failover would keep |
| One direction stops after a role change, `INFO ALL` all `RUNNING`, `INFO DISTPATH` says the service is not available | Distribution Service alive with no port ([F22](../findings.md#f22)). The controller kills it after 60 s and it comes back | On a node without the watch: `kill` the `distsrvr` process; the Service Manager relaunches it |
| GG_B only has adminsrvr | [F5](../findings.md#f5-open) | `systemctl restart ogg-ha` on prm3 |
| B2A times out, `OGG-10401` | distribution server stuck on the dead VIP | `systemctl restart ogg-ha` on prm3 |
| A row does not arrive, Extract keeps an old checkpoint | transaction left open | `send extract exta, showtrans`; `SKIPTRANS <xid>` only with Items = 0 and no such XID in `GV$TRANSACTION` |

Do not drop test tables while trail still holds their changes ([F6](../findings.md#f6)).
