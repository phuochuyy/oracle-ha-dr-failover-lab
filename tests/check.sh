#!/bin/bash
# Credentials come from lab.env at the repo root (see lab.env.example), never from the script.
. "$(cd "$(dirname "$0")/.." && pwd)/lab.env" 2>/dev/null
: "${DGADMIN_PASSWORD_A:?set in lab.env}" "${DGADMIN_PASSWORD_B:?set in lab.env}" "${OGG_PASSWORD:?set in lab.env}" "${APP_PASSWORD:?set in lab.env}"
# check.sh <tag>: tạm dừng workload, chờ GG hội tụ, lấy dữ liệu 2 site và chạy verify.py
S=$(cd "$(dirname "$0")" && pwd)
CA="(DESCRIPTION=(CONNECT_TIMEOUT=5)(RETRY_COUNT=3)(FAILOVER=on)(ADDRESS_LIST=(LOAD_BALANCE=off)(ADDRESS=(PROTOCOL=TCP)(HOST=prm-scan.rac)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=stb-scan.rac)(PORT=1521)))(CONNECT_DATA=(SERVICE_NAME=ogg_a.rac)))"
CB="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=prm3.rac)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=ogg_b.rac)))"
tag=${1:-check}; out=$S/../results/raw/$tag; mkdir -p $out
wl_start() { scp -q $S/wl.sh oracle@prm3:/tmp/wl.sh; ssh -o BatchMode=yes oracle@prm3 "chmod 700 /tmp/wl.sh; rm -f /tmp/wl.stop; echo $1 > /tmp/wl.phase
  export APP_PASSWORD='$APP_PASSWORD'
  nohup /tmp/wl.sh A '$CA' >/dev/null 2>&1 </dev/null &
  nohup /tmp/wl.sh B '$CB' >/dev/null 2>&1 </dev/null &"; }
# dừng workload để đối chiếu trên tập dữ liệu cố định
ssh -o BatchMode=yes oracle@prm3 'touch /tmp/wl.stop; for i in $(seq 1 60); do pgrep -f /tmp/wl.sh >/dev/null || break; sleep 1; done'
dump() { ssh -o BatchMode=yes oracle@prm3 ". ~/.bash_profile >/dev/null 2>&1; sqlplus -s -L 'app/${APP_PASSWORD}@$1' <<SQL
set heading off feedback off pages 0 lines 100
select site||' '||seq from app.txn order by site, seq;
exit
SQL" | grep -E '^[AB] [0-9]+$'; }
# chờ 2 site hội tụ (số dòng bằng nhau ổn định 2 lần liên tiếp)
prev=""
for i in $(seq 1 30); do   # tối đa 5 phút
  dump "$CA" > $out/rows_A.txt; dump "$CB" > $out/rows_B.txt
  cur="$(wc -l < $out/rows_A.txt) $(wc -l < $out/rows_B.txt)"
  read -r na nb <<< "$cur"; [ "$na" = "$nb" ] && [ "$cur" = "$prev" ] && break; prev=$cur; sleep 10
done
scp -q oracle@prm3:/tmp/wl_A.log oracle@prm3:/tmp/wl_B.log $out/
python3 -I $S/verify.py $out/wl_A.log $out/wl_B.log $out/rows_A.txt $out/rows_B.txt; rc=$?
[ -n "${2:-}" ] && wl_start $2      # check.sh <tag> <phase kế tiếp>: chạy lại workload
exit $rc
