#!/bin/bash
# Snapshot standby drill on Region B (orcl3 -> ORCL3_STB on stb3), run in the dg-b scenario.
#   1. FSFO off (a snapshot standby cannot be the fast-start failover target)
#   2. CONVERT DATABASE TO SNAPSHOT STANDBY: the standby opens read-write for testing
#   3. a test table written on the snapshot standby, while the primary keeps committing
#      (redo still arrives on the standby, it is not applied)
#   4. CONVERT back to PHYSICAL STANDBY: the test change is discarded, the redo received meanwhile is applied
#   5. FSFO on again
# Uses DRILLPDB (BANKDB scale 1, present on both sides). Broker as C##DGADMIN (tests/dg.sh).
# usage (from the repo root): ./tests/snapshot_standby.sh
set -eu
cd "$(dirname "$0")/.."
out=results/snapshot-standby.log; : > "$out"
ENV=". ~/.bash_profile >/dev/null 2>&1"
say() { echo "$(date +%T) $*" | tee -a "$out"; }
dg() { ./tests/dg.sh prm3 orcl3 "$@" | tee -a "$out"; }
sql() { ssh -o BatchMode=yes oracle@$1 "$ENV; sqlplus -s / as sysdba" 2>&1 | grep -vE "^$" | tee -a "$out"; }
lag() { printf "set heading off feedback off\nselect name || ' ' || value from v\$dataguard_stats where name in ('transport lag', 'apply lag');\nexit\n" \
        | ssh -o BatchMode=yes oracle@stb3 "$ENV; sqlplus -s / as sysdba" | grep -vE "^$" | tee -a "$out"; }
rows() {   # rows <host>: test rows of this drill in DRILLPDB
  printf "set heading off feedback off\nalter session set container = drillpdb;\nselect '%s: ' || (select count(*) from bank.transfer_note where note like 'snapshot-drill%%') || ' snapshot-drill rows, ' || (select count(*) from bank.transfer_note where note = 'primary-during-snapshot') || ' primary rows' from dual;\nexit\n" "$1" \
    | ssh -o BatchMode=yes oracle@$1 "$ENV; sqlplus -s / as sysdba" | grep -vE "^$|Session altered" | tee -a "$out"
}

wait_lag0() {   # first attempt: the broker said SUCCESS with apply lag 5 h 53 min (stb3 had just been started)
  for i in $(seq 1 60); do
    l=$(printf "set heading off feedback off\nselect value from v\$dataguard_stats where name = 'apply lag';\nexit\n" \
        | ssh -o BatchMode=yes oracle@stb3 "$ENV; sqlplus -s / as sysdba" | grep -oE "\+[0-9 :]+" | head -n 1)
    [ "$l" = "+00 00:00:00" ] && break; sleep 10
  done
  say "apply lag $l"
}

say "== before"; dg "show configuration"; lag
sql prm3 <<'SQL'
alter session set container = drillpdb;
create table bank.transfer_note (id number generated always as identity, note varchar2(40), created timestamp default systimestamp);
SQL
# the table must be on the standby before it is converted
wait_lag0

say "== 1. FSFO off"; dg "disable fast_start failover"
say "== 2. convert to snapshot standby"; t0=$(date +%s)
dg "convert database 'ORCL3_STB' to snapshot standby"
say "converted after $(( $(date +%s) - t0 )) s"
sql stb3 <<'SQL'
select database_role, open_mode from v$database;
select name, guarantee_flashback_database gfd, round(storage_size / 1048576) mb from v$restore_point;
alter pluggable database drillpdb open;
SQL

say "== 3. write on the snapshot standby, and on the primary at the same time"
sql stb3 <<'SQL'
alter session set container = drillpdb;
insert into bank.transfer_note (note) select 'snapshot-drill ' || level from dual connect by level <= 1000;
update bank.accounts set balance = balance + 1 where account_id <= 100;
commit;
SQL
sql prm3 <<'SQL'
alter session set container = drillpdb;
insert into bank.transfer_note (note) values ('primary-during-snapshot');
commit;
alter session set container = cdb$root;
alter system archive log current;
SQL
sleep 10
rows stb3; rows prm3; lag

say "== 4. convert back to physical standby"; t0=$(date +%s)
dg "convert database 'ORCL3_STB' to physical standby"
say "converted back after $(( $(date +%s) - t0 )) s"
# the broker leaves the standby MOUNTED after the conversion: reopen it read-only (Active Data Guard)
dg "edit database 'ORCL3_STB' set state='APPLY-OFF'"
sql stb3 <<'SQL'
alter database open read only;
-- PERF has STANDBYS=NONE (no datafiles here): "all" failed with ORA-65152 on the second run
alter pluggable database all except perf open read only;
select database_role, open_mode from v$database;
select count(*) restore_points from v$restore_point;
SQL
dg "edit database 'ORCL3_STB' set state='APPLY-ON'"
wait_lag0
rows stb3
# the accounts update made on the snapshot standby must be gone too: checksums equal the primary's
# the standby instance is ORCL3 (default SID on stb3) — VERIFY_SID=ORCL3_STB printed "no output" on run 2
ssh -o BatchMode=yes oracle@stb3 "cd ~/brlab 2>/dev/null && BANKDB_DIR=~/bankdb ./04-scripts/verify_drillpdb.sh" 2>&1 | tee -a "$out" || true

say "== 5. FSFO on, clean up"
dg "enable fast_start failover" "show configuration"
sql prm3 <<'SQL'
alter session set container = drillpdb;
drop table bank.transfer_note purge;
SQL
