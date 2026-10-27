#!/bin/bash
# Credentials come from lab.env at the repo root (see lab.env.example), never from the script.
. "$(cd "$(dirname "$0")/.." && pwd)/lab.env" 2>/dev/null
: "${DB_PASSWORD:?set in lab.env}" "${OGG_PASSWORD:?set in lab.env}" "${APP_PASSWORD:?set in lab.env}"
# timeline.sh <outfile> <seconds>: mỗi 5s ghi trạng thái DB role / GG_A / path / workload
out=$1 dur=${2:-900} end=$(( $(date +%s) + dur ))
SSH="ssh -o BatchMode=yes -o ConnectTimeout=3"
running() { [ "$(virsh -c qemu:///system domstate $1 2>/dev/null | head -1)" = running ]; }
while [ $(date +%s) -lt $end ] && [ ! -f $out.stop ]; do
  role=""; gnode=""
  for h in prm1 stb1; do running $h || { role="$role $h:DOWN"; continue; }
    r=$(timeout 15 $SSH oracle@$h '. ~/.bash_profile >/dev/null 2>&1; export ORACLE_SID=$(pgrep -a -f "ora_pmon_orcl" | sed "s/.*ora_pmon_//" | head -1); sqlplus -s / as sysdba @/home/oracle/role.sql' 2>/dev/null | head -1 | sed 's/ /_/g')
    role="$role $h:${r:-?}"
    n=$(timeout 10 $SSH root@$h "/u01/app/23.26.0/grid/bin/agctl status goldengate GG_A" 2>/dev/null | grep -oE 'running on [a-z0-9]+' | awk '{print $3}')
    [ -n "$n" ] && gnode=$n
  done
  gg="-"
  if [ -n "$gnode" ]; then
    gg=$(printf "CONNECT http://localhost:9100 DEPLOYMENT GG_A AS oggadmin PASSWORD ${OGG_PASSWORD}\nINFO ALL\nINFO DISTPATH ALL\n" \
      | timeout 30 $SSH oracle@$gnode "cat > /tmp/tl.oby; /u01/app/gg/bin/adminclient -O /tmp/tl.oby 2>&1" \
      | awk '/^EXTRACT|^REPLICAT/{printf "%s=%s ", $3, $2} /^ A2B/{printf "A2B=%s ", $2}')
  fi
  b2a=$(printf "CONNECT http://localhost:9100 DEPLOYMENT GG_B AS oggadmin PASSWORD ${OGG_PASSWORD}\nINFO DISTPATH B2A DETAIL\n" \
      | timeout 30 $SSH oracle@prm3 "cat > /tmp/tl.oby; /u01/app/gg/bin/adminclient -O /tmp/tl.oby 2>&1" \
      | awk '/Status:/{s=$2} /Target:/{sub(/.*wss:\/\//,""); sub(/:443.*/,""); t=$0} END{printf "B2A=%s->%s", s, t}')
  wa=$(timeout 10 $SSH oracle@prm3 'tail -n 1 /tmp/wl_A.log' 2>/dev/null | awk '{print $3"@"$4}')
  wb=$(timeout 10 $SSH oracle@prm3 'tail -n 1 /tmp/wl_B.log' 2>/dev/null | awk '{print $3"@"$4}')
  echo "$(date +%T) |$role | GG_A@${gnode:-none}: $gg| $b2a | wlA=$wa wlB=$wb" >> $out
  sleep 5
done
