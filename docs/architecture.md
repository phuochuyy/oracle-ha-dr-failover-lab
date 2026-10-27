# Architecture

## Hosts

| VM | Role | Network | RAM |
|----|------|---------|-----|
| prm1, prm2 | Region A primary RAC `orcl` | 192.168.104.x | 7 GB |
| stb1, stb2 | Region A standby RAC `orcl_stb` (Active Data Guard) | 192.168.105.x | 5 GB |
| prm3 | Region B primary `orcl3` (no Grid) + GG_B | | 7 GB |
| stb3 | Region B standby `ORCL3_STB` | | 5 GB |
| obs-r1, obs-r2 | FSFO observers (Region A / B) | | 1 GB |

Oracle Linux 9.8 · Database / Grid Infrastructure 23ai (23.26) · GoldenGate 23.26.1 Microservices.
KVM/libvirt on one 23 GB host — [`lab/labctl.sh`](../lab/labctl.sh) starts only the VMs a scenario needs.

## Data Guard

| | Region A (`dg_orcl`) | Region B (`dg_orcl3`) |
|-|----------------------|-----------------------|
| Protection | MaxAvailability, SYNC | MaxAvailability, SYNC |
| FSFO | Zero Data Loss Mode, threshold 30 s, auto-reinstate, observer obs-r1 | observer obs-r2 |
| Standby | Real-Time Query (ADG) | physical |

When a region's standby is shut down for a long time, `labctl.sh` disables FSFO, sets
`TRANSPORT-OFF` and removes `HANDLEDLFAILOVER` from the Extract (otherwise Extract waits for redo
the standby will never receive); it reverses all three when the standby is back.

## GoldenGate

| | GG_A (Region A) | GG_B (Region B) |
|-|-----------------|-----------------|
| PDB | ORCLPDB2 | GGREPL |
| Processes | Integrated Extract EXTA, Parallel Replicat REPA | EXTB, REPB |
| Outgoing path | A2B, trail `ea` | B2A, trail `eb` |
| Deployment storage | DBFS in the database, mounted `/mnt/dbfs` | DBFS, mounted `/mnt/dbfs` |
| HA controller | XAG + FAN callout | systemd `ogg-ha` controller |
| Address | VIP `gg-a.rac` (primary cluster) / `gg-a-stb.rac` (standby cluster), nginx :443 | prm3.rac / stb3.rac |

- **Loop prevention:** Replicat writes with tag `00`; Extract `TRANLOGOPTIONS EXCLUDETAG 00`.
- **Conflicts:** Auto-CDR (`DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR`), latest-timestamp per row.
- **Role transitions:** Extract `TRANLOGOPTIONS HANDLEDLFAILOVER` never ships changes the standby
  has not received, so a failover cannot leave the peer region ahead of the new primary.

### Why DBFS for the deployment

The deployment (checkpoints, trails, parameter files) must be on the new primary after a role
transition. DBFS stores it inside the protected database, so Data Guard carries it to the standby
with the same zero-data-loss guarantee as the business data — no separate ACFS replication to
operate. An earlier iteration of the lab used ACFS on the primary cluster only.

### Resource chain on RAC (CRS)

```
ora.<db>.ogg_a.svc  (role PRIMARY only)
   └─ pullup:always ─▶ xag.GG_A.goldengate ── hard ──▶ xag.GG_A-vip.vip, dbfs_ogg, nginx
                               └─ pullup ─▶ ogg_pathsync   (re-points A2B / B2A)
FAN "service=ogg_a status=up" ─▶ racg/usrco/ogg-fan-callout.sh ─▶ crsctl start xag.GG_A.goldengate
```

The pullup covers switchovers; the FAN callout covers Fast-Start Failover, where CRS starts the
service without pullups ([finding F1](findings.md#f1)).
