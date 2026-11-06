#!/bin/bash
# One row each way through GoldenGate: insert on one site, wait for it on the other, delete it, wait for the delete.
# The table is the CDC test table of the automation project (app.cdc_events, Auto-CDR, in both PDBs).
# Connects as SYSDBA over ssh on the primary of each region; no password involved. Exit 0 only if every step arrived.
# usage (from the host): tests/gg_ping.sh [region A primary host] [region B primary host]   defaults: prm1 prm3
set -u
HA=${1:-prm1} HB=${2:-prm3}
sql() {  # sql <host> <pdb> <statement>   -> first line of output
  { echo "set heading off feedback off pages 0 lines 200"; echo "alter session set container=$2;"; echo "$3"; echo "exit"; } \
    | ssh -o BatchMode=yes oracle@$1 '. ~/.bash_profile >/dev/null 2>&1; sqlplus -s / as sysdba' 2>&1 | grep -vE '^$' | head -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}
wait_count() {  # wait_count <host> <pdb> <seq> <expected> -> seconds, or exit 1 after 120 s
  local s=$SECONDS n
  while [ $((SECONDS - s)) -lt 120 ]; do
    n=$(sql "$1" "$2" "select count(*) from app.cdc_events where site='TEST' and seq=$3;")
    [ "$n" = "$4" ] && { echo $((SECONDS - s)); return 0; }
    sleep 1
  done
  echo "timeout"; return 1
}
rc=0
base=$(date +%s)
one_way() {  # one_way <label> <from host> <from pdb> <to host> <to pdb> <seq>
  local t r
  r=$(sql "$2" "$3" "insert into app.cdc_events(site,seq,account,amount,note,created) values ('TEST',$6,1,0,'gg_ping',systimestamp);"$'\n'"commit;")
  [ -z "$r" ] || { echo "$1: insert failed: $r"; rc=1; return; }
  t=$(wait_count "$4" "$5" "$6" 1) || rc=1
  echo "$1 insert arrived: ${t} s"
  r=$(sql "$2" "$3" "delete app.cdc_events where site='TEST' and seq=$6;"$'\n'"commit;")
  [ -z "$r" ] || { echo "$1: delete failed: $r"; rc=1; return; }
  t=$(wait_count "$4" "$5" "$6" 0) || rc=1
  echo "$1 delete arrived: ${t} s"
}
one_way "A->B" "$HA" ORCLPDB2 "$HB" GGREPL "$base"
one_way "B->A" "$HB" GGREPL "$HA" ORCLPDB2 "$((base + 1))"
exit $rc
