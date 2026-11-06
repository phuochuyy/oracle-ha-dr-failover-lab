# 07 After a failover

A failover opens a new incarnation. Close these before calling the incident over.

1. **Protection:** `show configuration` is `SUCCESS`, `fs_failover_status = SYNCHRONIZED`, standby lag 0.
2. **Data:** no committed transaction lost (`tests/check.sh` in a test; in production, the application's reconciliation).
3. **Backups:** a RAC backup taken on the standby is not recorded until the catalog is resynced from the primary. The scheduled
   job does this before every backup (`rac_backup_job.sh`). Take a new level 0 soon: older backups belong to the previous
   incarnation, and a restore through them can fail with `ORA-01207` (backup lab, drill 1b).
4. **Keys:** both sites `OPEN`, `AUTOLOGIN` in `v$encryption_wallet`, and the same master key ID.
5. **Network encryption:** new sessions on the new primary are encrypted (`v$session_connect_info`).
6. **Health check:** `~/health/alerts.log` on each site. `BACKUP_ROLE` in `~/brlab/health.env` follows the site that takes backups.
7. **Record:** timeline, times against the [targets](README.md), what went wrong, what changes.
