#!/bin/bash
# Run 7: Region B after hardening: switchover, switchback, then a power-off of its primary. One stage per call, so each
# result can be read before the next event. Follows tests/README.md and docs/runbooks.
# The client runs on prm1: on prm3 it would die with the machine under test.
# usage (from the host): tests/r7_region_b.sh prep | t0 | t1 | t2 | t3 | reinstate | t4 | final | clean
set -u
S=$(cd "$(dirname "$0")" && pwd); OUT=$S/../results; TL=$OUT/timelines
export WL_HOST=prm1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=3"
running() { [ "$(virsh -c qemu:///system domstate "$1" 2>/dev/null | head -1)" = running ]; }
ssq() { $SSH oracle@"$1" '. ~/.bash_profile >/dev/null 2>&1; sqlplus -s / as sysdba'; }
role() { printf "set heading off feedback off pages 0\nselect database_role||':'||open_mode from v\$database;\nexit\n" | timeout 15 $SSH oracle@"$1" '. ~/.bash_profile >/dev/null 2>&1; sqlplus -s -L / as sysdba' 2>/dev/null | tr -d '\n' | sed 's/PHYSICAL STANDBY/STB/; s/PRIMARY/PRM/; s/READ WRITE/RW/; s/READ ONLY WITH APPLY/ROA/; s/READ ONLY/RO/' | cut -c1-20; }
primary() { local h; for h in prm3 stb3; do running "$h" && [ "$(role "$h" | cut -d: -f1)" = PRM ] && { echo "$h"; return; }; done; }
timeline() {  # every 5 s: role of each site, where GG_B runs, its processes, last line of each client
  local out=$1 end=$(( $(date +%s) + $2 )) line h g
  while [ "$(date +%s)" -lt "$end" ] && [ ! -f "$out.stop" ]; do
    line="$(date +%T) |"; g=""
    for h in prm3 stb3; do
      if running "$h"; then line="$line $h:$(role "$h")"; timeout 5 $SSH root@"$h" 'pgrep -x ServiceManager' >/dev/null 2>&1 && g=$h
      else line="$line $h:DOWN"; fi
    done
    line="$line | GG_B@${g:-none}:"
    [ -n "$g" ] && line="$line $(timeout 30 "$S/gg.sh" "$g" GG_B "info all" "info distpath all" 2>/dev/null | awk '/^EXTRACT|^REPLICAT/{printf "%s=%s ", $3, $2} /^ *B2A/{printf "B2A=%s ", $2}')"
    line="$line | wlA=$(timeout 8 $SSH oracle@$WL_HOST 'tail -n 1 /tmp/wl_A.log' 2>/dev/null | awk '{print $3"@"$4}') wlB=$(timeout 8 $SSH oracle@$WL_HOST 'tail -n 1 /tmp/wl_B.log' 2>/dev/null | awk '{print $3"@"$4}')"
    echo "$line" >> "$out"
    sleep 5
  done
}
stage() {  # stage <tag> <next phase> <seconds to watch after the event> <event...>
  local tag=$1 next=$2 secs=$3 tl; shift 3
  rm -f "$TL/r7_$tag.log.stop"
  timeline "$TL/r7_$tag.log" $((secs + 80)) & tl=$!
  sleep 20
  { echo "event start $(date +%T.%3N): $*"; timeout 600 "$@"; rc=$?; echo "event end $(date +%T.%3N) rc=$rc"; } 2>&1 | tee "$TL/r7_$tag.event.txt"
  sleep "$secs"
  touch "$TL/r7_$tag.log.stop"; wait "$tl"; rm -f "$TL/r7_$tag.log.stop"
  "$S/check.sh" "r7_$tag" "$next"; echo "check rc=$?"
}
showtrans() { timeout 60 "$S/gg.sh" "$1" GG_B "send extract extb, showtrans" | tail -n 1 | cut -c1-100; }
gate() {  # gate <primary host> <alias>: the conditions for a power-off (docs/runbooks); exit if one fails
  local p=$1 a=$2 st h
  [ "$(primary)" = "$p" ] || { echo "GATE: primary is not $p"; exit 1; }
  st=$(timeout 60 "$S/dg.sh" "$p" "$a" "show configuration" "show fast_start failover")
  grep -q '^SUCCESS' <<< "$st" || { echo "GATE: configuration is not SUCCESS"; exit 1; }
  grep -q 'Enabled in Zero Data Loss' <<< "$st" || { echo "GATE: FSFO is not enabled in Zero Data Loss Mode"; exit 1; }
  grep -qE 'Observer: +obs-r2' <<< "$st" || { echo "GATE: observer obs-r2 is not there"; exit 1; }
  for h in prm3 stb3; do running "$h" && $SSH root@"$h" 'pgrep -x rman' >/dev/null 2>&1 && { echo "GATE: RMAN is running on $h"; exit 1; }; done
  [ "$(showtrans "$p")" = "No transactions found." ] || { echo "GATE: EXTB has an open transaction"; showtrans "$p"; exit 1; }
  echo "gate passed: $p primary, SUCCESS, Zero Data Loss, observer up, no RMAN, no open transaction in EXTB"
}
gg_ok() {  # after a role change: GG_B processes running and the path to Region A up, on the Region B primary
  local p i r; p=$(primary)
  for i in $(seq 1 30); do
    r=$(timeout 60 "$S/gg.sh" "$p" GG_B "info all" "info distpath all" 2>/dev/null | awk '/^EXTRACT|^REPLICAT/{printf "%s=%s ", $3, $2} /^ *B2A/{printf "B2A=%s ", $2}')
    grep -q 'EXTB=RUNNING REPB=RUNNING B2A=running' <<< "$r" && { echo "GG_B on $p: $r"; return 0; }
    sleep 10
  done
  echo "GG_B on $p NOT all running after 5 min: $r"; return 1
}
case ${1:?stage} in
prep)
  "$S/dg.sh" prm3 orcl3 "show configuration" "show fast_start failover" | grep -E 'Threshold|Fast-Start Failover:|Observer:|^(SUCCESS|WARNING|ERROR)'
  $SSH oracle@$WL_HOST 's=$(date +%s); for f in A B; do [ -f /tmp/wl_$f.log ] && mv /tmp/wl_$f.log /tmp/wl_prev_${f}_$s.log; done; true'
  for x in "prm1 ORCLPDB2" "prm3 GGREPL"; do set -- $x
    { echo "alter session set container=$2;"; cat "$S/sql/create_txn.sql"; echo exit; } | ssq "$1" | grep -E 'ORA-|created|completed' | cut -c1-80
  done
  ;;
t0) "$S/check.sh" r7_t0_baseline switchover; echo "check rc=$?" ;;
t1) showtrans prm3; stage t1_switchover switchback 150 "$S/dg.sh" prm3 orcl3 "switchover to orcl3_stb" ;;
t2) gg_ok; showtrans stb3; stage t2_switchback failover_prm3 150 "$S/dg.sh" stb3 orcl3_stb "switchover to orcl3" ;;
t3) gate prm3 orcl3
    gg_ok || exit 1
    printf "alter session set container=ggrepl;\nset lines 120\nselect capture_name, required_checkpoint_scn from dba_capture;\nexit\n" | ssq prm3 | grep -E 'OGG|ORA-'
    stage t3_failover_prm3 after_failover 300 virsh -c qemu:///system destroy prm3 ;;
reinstate)  # start the old primary: time from VM start to SUCCESS
  t0=$(date +%s); virsh -c qemu:///system start prm3 >/dev/null
  until timeout 30 "$S/dg.sh" stb3 orcl3_stb "show configuration" 2>/dev/null | grep -qE '^SUCCESS'; do
    sleep 5; [ $(( $(date +%s) - t0 )) -gt 900 ] && { echo "no SUCCESS 15 min after starting prm3"; timeout 30 "$S/dg.sh" stb3 orcl3_stb "show configuration" | cut -c1-100; exit 1; }
  done
  echo "prm3 start to SUCCESS: $(( $(date +%s) - t0 )) s" | tee "$TL/r7_t3_reinstate.log"
  timeout 30 "$S/dg.sh" stb3 orcl3_stb "show configuration" | grep -vE '^$' | cut -c1-100
  gg_ok
  ;;
t4) gate stb3 orcl3_stb; stage t4_switchback final 150 "$S/dg.sh" stb3 orcl3_stb "switchover to orcl3" ;;
final) "$S/check.sh" r7_t5_final; echo "check rc=$?" ;;
clean)  # order from tests/README.md: client stopped (final did it), Replicats past the last row, then each site in turn
  p=$(primary); [ -n "$p" ] || { echo "no Region B primary"; exit 1; }
  $SSH oracle@$WL_HOST 'pgrep -f "[/]tmp/wl.sh"' >/dev/null && { echo "client still running on $WL_HOST"; exit 1; }
  for x in "prm1 GG_A repa ORCLPDB2" "$p GG_B repb GGREPL"; do set -- $x
    for i in $(seq 1 30); do   # lag 0 and a read checkpoint newer than the end of the client (README step 2)
      l=$(timeout 60 "$S/gg.sh" "$1" "$2" "info $3" | grep -E 'Checkpoint Lag' | head -n 1)
      grep -qE 'Checkpoint Lag +00:00:0[0-9]' <<< "$l" && break; sleep 10
    done
    echo "$2 $3: $l" | tr -s ' ' | cut -c1-140; sleep 30
    timeout 120 "$S/gg.sh" "$1" "$2" "stop replicat $3" | tail -n 1 | cut -c1-90
    { echo "alter session set container=$4;"; cat "$S/sql/drop_txn.sql"; echo exit; } | ssq "$1" | grep -E 'ORA-|dropped|completed' | cut -c1-80
    timeout 120 "$S/gg.sh" "$1" "$2" "start replicat $3" | tail -n 1 | cut -c1-90
  done
  ;;
esac
