#!/bin/bash
# Application Continuity test: two role-based services on DRILLPDB (both clusters), a test user and a table. Idempotent.
#   bank_app    what an application should use: Transparent Application Continuity + Transaction Guard
#   bank_plain  same placement, no failover options: the comparison
# DRILLPDB is not replicated by GoldenGate, so this test stays out of the Active-Active path.
# usage (from the host, with the primary on prm1): tests/tac_setup.sh setup | drop
# Password from ../lab.env, over stdin only.
set -eu
. "$(cd "$(dirname "$0")/.." && pwd)/lab.env"
: "${TAC_APP_PASSWORD:?set in lab.env}"
ENV='. ~/.bash_profile >/dev/null 2>&1'
PRIM=${PRIM:-prm1}
sql() { ssh -o BatchMode=yes oracle@$PRIM "$ENV; sqlplus -s / as sysdba" 2>&1 | grep -vE '^$'; }
svc() {  # svc <host> <db> <inst prefix>
  local h=$1 db=$2 i=$3
  ssh -o BatchMode=yes oracle@$h "$ENV
    srvctl config service -db $db -service bank_app >/dev/null 2>&1 ||
      srvctl add service -db $db -service bank_app -pdb DRILLPDB -preferred ${i}1 -available ${i}2 -role PRIMARY \
        -failovertype AUTO -failover_restore AUTO -commit_outcome TRUE -retention 86400 -replay_init_time 600 \
        -failoverretry 30 -failoverdelay 10 -notification TRUE -drain_timeout 30 -stopoption IMMEDIATE -clbgoal SHORT -rlbgoal SERVICE_TIME
    srvctl config service -db $db -service bank_plain >/dev/null 2>&1 ||
      srvctl add service -db $db -service bank_plain -pdb DRILLPDB -preferred ${i}1 -available ${i}2 -role PRIMARY \
        -failovertype NONE -commit_outcome FALSE
    srvctl config service -db $db -service bank_app | grep -E 'Service name|Service role|Failover type|Commit Outcome|Failover restore|Retention|Replay'"
}
case ${1:?setup or drop} in
setup)
  svc prm1 orcl orcl
  svc stb1 orcl_stb orcl_stb
  ssh -o BatchMode=yes oracle@$PRIM "$ENV; srvctl start service -db orcl -service bank_app 2>&1 | grep -v PRCC-1014 | grep -v CRS-5702 || true
    srvctl start service -db orcl -service bank_plain 2>&1 | grep -v PRCC-1014 | grep -v CRS-5702 || true
    srvctl status service -db orcl | grep bank_"
  { cat <<SQL
alter session set container = drillpdb;
whenever sqlerror continue
create user tac_app identified by "$TAC_APP_PASSWORD" default tablespace bank_data quota 64m on bank_data;
grant create session, create table to tac_app;
-- replay keeps the original time values instead of taking new ones
grant keep date time to tac_app;
create table tac_app.txn_log (client varchar2(12) not null, seq number not null, step number not null,
  inst varchar2(30), ts timestamp default systimestamp not null);
create index tac_app.txn_log_ix on tac_app.txn_log (client, seq);
select username, account_status, default_tablespace from dba_users where username = 'TAC_APP';
exit
SQL
  } | sql | grep -vE 'ORA-01920|ORA-00955|ORA-01408|^ERROR at|^\*|^create |^ *[0-9]+ '
  ;;
drop)
  for x in "prm1 orcl" "stb1 orcl_stb"; do set -- $x
    ssh -o BatchMode=yes oracle@$1 "$ENV; for s in bank_app bank_plain; do srvctl stop service -db $2 -service \$s -force 2>/dev/null; srvctl remove service -db $2 -service \$s -force 2>&1 | head -1; done"
  done
  printf 'alter session set container = drillpdb;\ndrop user tac_app cascade;\nexit\n' | sql
  ;;
esac
