#!/bin/bash
# Controlled test: what stops Extract when the only standby is down? No failover, no new incarnation.
#   1. standby down, HANDLEDLFAILOVER on,  no log switch  -> does a row still reach the other region?
#   2. standby down, HANDLEDLFAILOVER on,  log switch     -> does Extract survive?
#   3. standby down, HANDLEDLFAILOVER off, log switch     -> the same, without the parameter
#   4. standby back, parameter back on
# usage (from the host, primary on prm1, no workload running): tests/r6_extract_standby_down.sh
set -u
S=$(cd "$(dirname "$0")" && pwd)
ENV='. ~/.bash_profile >/dev/null 2>&1'
PRM=/mnt/dbfs/ogg/GG_A/etc/conf/ogg/exta.prm
sq() { ssh -o BatchMode=yes oracle@prm1 "$ENV; sqlplus -s / as sysdba"; }
state() {
  local e f
  e=$("$S/gg.sh" prm1 GG_A "info extract exta" 2>&1 | grep -E 'Status|^ +2026' | tr -s ' ' | sed -E 's/Extract EXTA Last Started [0-9-]+ [0-9:]+ //' | tr '\n' ' ')
  f=$(printf 'set heading off feedback off pages 0\nselect fs_failover_status, protection_level from v$database;\nselect max(sequence#) from v$log where status=chr(67)||chr(85)||chr(82)||chr(82)||chr(69)||chr(78)||chr(84);\nexit\n' | sq | grep -v '^$' | tr -s ' \t' ' ' | tr '\n' ' ')
  echo "$(date +%T) $1 | EXTA: $e| $f"
}
ping_ab() {  # one row A->B, wait up to 90 s
  local seq n i
  seq=$(date +%s)
  printf "alter session set container=ORCLPDB2;\ninsert into app.cdc_events(site,seq,account,amount,note,created) values ('TEST',$seq,1,0,'extract_test',systimestamp);\ncommit;\nexit\n" | sq >/dev/null
  for i in $(seq 1 18); do
    n=$(printf "set heading off feedback off pages 0\nalter session set container=GGREPL;\nselect count(*) from app.cdc_events where site='TEST' and seq=$seq;\nexit\n" | ssh -o BatchMode=yes oracle@prm3 "$ENV; sqlplus -s / as sysdba" | tr -dc 0-9)
    [ "$n" = 1 ] && { echo "$(date +%T) row A->B arrived after $((i*5-5)) s"; return 0; }
    sleep 5
  done
  echo "$(date +%T) row A->B did NOT arrive in 90 s"
  return 1
}
switch() { printf 'alter system archive log current;\nexit\n' | sq >/dev/null; echo "$(date +%T) log switch"; }
hdl() {
  "$S/gg.sh" prm1 GG_A "stop extract exta" >/dev/null 2>&1
  for i in $(seq 1 30); do "$S/gg.sh" prm1 GG_A "info extract exta" 2>&1 | grep -qE 'Status +(STOPPED|ABENDED)' && break; sleep 2; done
  if [ "$1" = off ]; then ssh -o BatchMode=yes oracle@prm1 "sed -i 's/^TRANLOGOPTIONS HANDLEDLFAILOVER/-- TRANLOGOPTIONS HANDLEDLFAILOVER/' $PRM"
  else ssh -o BatchMode=yes oracle@prm1 "sed -i 's/^-- TRANLOGOPTIONS HANDLEDLFAILOVER/TRANLOGOPTIONS HANDLEDLFAILOVER/' $PRM"; fi
  "$S/gg.sh" prm1 GG_A "start extract exta" >/dev/null 2>&1
  echo "$(date +%T) HANDLEDLFAILOVER $1: $(ssh -o BatchMode=yes oracle@prm1 "grep HANDLEDL $PRM")"
  sleep 20
}
echo "## baseline"; state start; ping_ab
echo; echo "## standby down, parameter on, no log switch"
echo "$(date +%T) virsh destroy stb1"; virsh -c qemu:///system destroy stb1 >/dev/null
sleep 45; state "+45s"; ping_ab; state after-row
echo; echo "## standby down, parameter on, log switch"
switch; sleep 30; state "+30s"; sleep 40; state "+70s"; ping_ab; state after-row
echo; echo "## standby down, parameter off, log switch"
hdl off; state started; ping_ab; switch; sleep 30; state "+30s"; sleep 40; state "+70s"; ping_ab; state after-row
echo; echo "## standby back, parameter on"
t0=$(date +%s); virsh -c qemu:///system start stb1 >/dev/null
until "$S/dg.sh" prm1 orcl "show configuration" 2>/dev/null | grep -qE '^SUCCESS'; do sleep 5; [ $(( $(date +%s) - t0 )) -gt 600 ] && { echo "no SUCCESS after 600 s"; break; }; done
echo "$(date +%T) stb1 start to SUCCESS: $(( $(date +%s) - t0 )) s"
hdl on; state started; ping_ab; switch; sleep 30; state "+30s"; ping_ab; state end
printf "alter session set container=ORCLPDB2;\ndelete app.cdc_events where site='TEST';\ncommit;\nexit\n" | sq >/dev/null
