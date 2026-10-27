#!/bin/bash
# Workload Active-Active (runs on prm3): APP_PASSWORD=... wl.sh SITE "<connect descriptor>"
# Mỗi giây 1 transaction, kết nối mới mỗi lần (như client có retry). Log: /tmp/wl_SITE.log
#   HH:MM:SS seq OK host phase   -> đã COMMIT thành công (phải có ở cả 2 site)
#   HH:MM:SS seq ERR <lỗi>        -> không chắc chắn
site=$1 conn=$2 log=/tmp/wl_$1.log
. ~/.bash_profile >/dev/null 2>&1
n=$(awk 'END{print $2+0}' $log 2>/dev/null); n=${n:-0}
while [ ! -f /tmp/wl.stop ]; do
  n=$((n+1)); phase=$(cat /tmp/wl.phase 2>/dev/null || echo base)
  out=$(timeout 40 sqlplus -s -L "app/${APP_PASSWORD:?}@$conn" <<SQL 2>&1
whenever sqlerror exit failure
set heading off feedback off pages 0
insert into app.txn(site,seq,phase) values ('$site',$n,'$phase');
commit;
select 'HOST='||sys_context('userenv','server_host') from dual;
exit
SQL
)
  rc=$?
  if [ $rc = 0 ] && h=$(grep -o 'HOST=[a-z0-9]*' <<< "$out"); then
    echo "$(date +%T) $n OK ${h#HOST=} $phase" >> $log
  else
    echo "$(date +%T) $n ERR rc=$rc $(grep -oE '(ORA|TNS)-[0-9]+' <<< "$out" | head -1)" >> $log
  fi
  sleep 1
done
