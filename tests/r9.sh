#!/bin/bash
# Run 9 stages (soak of stb1 at 7 GB; same stages as run 6), one per call, so each result can be read before the next event. Follows tests/README.md and docs/runbooks.
# usage (from the host): tests/r9.sh prep | t0 | t1 | t2 | t3 | reinstate <vm> <new primary host> <alias> <tag> | soak <minutes> | t5 | final
set -u
S=$(cd "$(dirname "$0")" && pwd); R=$S/..
OUT=$R/results; TL=$OUT/timelines; TAC=$OUT/app-continuity
ssq() { ssh -o BatchMode=yes oracle@"$1" '. ~/.bash_profile >/dev/null 2>&1; sqlplus -s / as sysdba'; }
stage() {  # stage <tag> <next phase> <client seconds> <event...>
  local tag=$1 next=$2 secs=$3; shift 3
  "$S/timeline.sh" "$TL/r9_$tag.log" $((secs + 60)) &
  local tl=$!
  "$S/tac_compare.sh" "$TAC/r9_$tag" "$secs" 20 "$@"
  touch "$TL/r9_$tag.log.stop"; wait $tl; rm -f "$TL/r9_$tag.log.stop"
  "$S/check.sh" "r9_$tag" "$next"
  echo "check rc=$?"
}
case ${1:?stage} in
prep)
  "$S/dg.sh" prm1 orcl "edit configuration set property FastStartFailoverThreshold = 90" "show fast_start failover" | grep -E 'Property|Threshold' | head -3
  for h in prm1 stb1; do scp -q "$S/sql/role.sql" oracle@$h:/home/oracle/role.sql; ssh -o BatchMode=yes root@$h 'systemctl stop rac-backup-1.timer rac-backup-0.timer rac-backup-validate.timer; systemctl list-timers --no-pager | grep -c rac-backup || true'; done
  ssh -o BatchMode=yes oracle@prm3 's=$(date +%s); for f in A B; do [ -f /tmp/wl_$f.log ] && mv /tmp/wl_$f.log /tmp/wl_prev_${f}_$s.log; done; true'
  for x in "prm1 ORCLPDB2" "prm3 GGREPL"; do set -- $x
    { echo "alter session set container=$2;"; cat "$S/sql/create_txn.sql"; echo exit; } | ssq "$1" | grep -E 'ORA-|created|completed' | cut -c1-80
  done
  ;;
t0) "$S/check.sh" r9_t0_baseline switchover; echo "check rc=$?" ;;
t1) stage t1_switchover switchback 180 "$S/dg.sh" prm1 orcl "switchover to orcl_stb" ;;
t2) stage t2_switchback failover_prm1 180 "$S/dg.sh" stb1 orcl_stb "switchover to orcl" ;;
t3) "$S/gg.sh" prm1 GG_A "send extract exta, showtrans" | tail -1
    stage t3_failover_prm1 soak 300 virsh -c qemu:///system destroy prm1 ;;
reinstate)  # reinstate <vm> <primary host> <alias> <tag>: time from VM start to SUCCESS
  vm=$2 h=$3 a=$4 tag=$5; t0=$(date +%s); virsh -c qemu:///system start "$vm" >/dev/null
  until "$S/dg.sh" "$h" "$a" "show configuration" 2>/dev/null | grep -qE '^SUCCESS'; do sleep 5; [ $(( $(date +%s) - t0 )) -gt 600 ] && { echo "no SUCCESS after 600 s"; break; }; done
  echo "$vm start to SUCCESS: $(( $(date +%s) - t0 )) s" | tee "$TL/r9_$tag.reinstate.log"
  ;;
soak)  # soak <minutes>: stb1 as primary under load; memory every 30 s
  m=${2:-30}; f=$OUT/maintenance/r9-stb1-soak-7g.txt; echo "# stb1 primary, 7 GB, workload running: time mem_avail_MB swap_used_MB si so load" > "$f"
  end=$(( $(date +%s) + m * 60 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    ssh -o BatchMode=yes -o ConnectTimeout=5 root@stb1 'echo "$(date +%T) $(awk "/MemAvailable/{print int(\$2/1024)}" /proc/meminfo) $(free -m | awk "/Swap/{print \$3}") $(vmstat 1 2 | tail -1 | awk "{print \$7,\$8}") $(cut -d" " -f1 /proc/loadavg)"' >> "$f" 2>&1 || echo "$(date +%T) stb1 no answer" >> "$f"
    sleep 30
  done
  sort -k3 -n "$f" | tail -1 | sed 's/^/highest swap: /'; grep -c 'no answer' "$f" | sed 's/^/no answer samples: /'
  ;;
t5) "$S/gg.sh" stb1 GG_A "send extract exta, showtrans" | tail -1
    stage t5_failover_stb1 final 300 virsh -c qemu:///system destroy stb1 ;;
final) "$S/check.sh" r9_t6_final; echo "check rc=$?" ;;
esac
