#!/bin/bash
# Run 10: power off one RAC node of the primary while the other is up. What should happen: Clusterware evicts the node,
# the surviving instance recovers the dead one's redo, services and GoldenGate move to the survivor, and Fast-Start Failover
# does NOT fire: the database is still open on the other node. Client: the Application Continuity pair, from the host.
# Needs prm1 and prm2 up with orcl on both, the standby and its observer up; prm3 may be off (memory).
# The node powered off is prm2: first the services and GoldenGate are moved there (move), so that the dead node is the one
# carrying them. prm2 is started again through labctl (back), which is the only allowed way to start it.
# usage (from the host): tests/r10_rac_node.sh move | run | back
set -u
S=$(cd "$(dirname "$0")" && pwd); OUT=$S/../results; TL=$OUT/timelines/r10_node_prm2.log; TAC=$OUT/app-continuity/r10_node_prm2
SSH="ssh -o BatchMode=yes -o ConnectTimeout=3"
GH=/u01/app/23.26.0/grid/bin
timeline() {
  local end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$end" ] && [ ! -f "$TL.stop" ]; do
    echo "$(date +%T) | $(timeout 10 $SSH oracle@prm1 ". ~/.bash_profile >/dev/null 2>&1; srvctl status database -db orcl | sed 's/Instance //; s/ is running on node / on /' | tr '\n' ' '; srvctl status service -db orcl -service bank_app | sed 's/Service //' | tr '\n' ' '" 2>/dev/null) | GG_A $(timeout 15 $SSH root@prm1 "$GH/agctl status goldengate GG_A" 2>/dev/null | grep -oE 'running on [a-z0-9]+|not running' | head -n 1) | $(timeout 20 "$S/dg.sh" prm1 orcl "show configuration" 2>/dev/null | grep -E 'Primary database|^(SUCCESS|WARNING|ERROR)' | tr -s ' ' | tr '\n' ' ')" >> "$TL"
    sleep 5
  done
}
case ${1:?move, run or back} in
move)
  $SSH oracle@prm1 '. ~/.bash_profile >/dev/null 2>&1; for s in ogg_a bank_app bank_plain secpdb_app; do srvctl relocate service -db orcl -service $s -oldinst orcl1 -newinst orcl2 2>&1 | grep -v "^$"; done; srvctl status service -db orcl'
  $SSH root@prm1 "$GH/agctl relocate goldengate GG_A --node prm2; $GH/agctl status goldengate GG_A"
  ;;
run)
  [ "$(timeout 20 $SSH oracle@prm1 '. ~/.bash_profile >/dev/null 2>&1; srvctl status database -db orcl' | grep -c 'is running')" = 2 ] || { echo "orcl is not running on both nodes"; exit 1; }
  "$S/gg.sh" prm2 GG_A "send extract exta, showtrans" | tail -n 1 | cut -c1-60
  rm -f "$TL" "$TL.stop"; timeline 420 & tl=$!
  "$S/tac_compare.sh" "$TAC" 300 30 virsh -c qemu:///system destroy prm2
  touch "$TL.stop"; wait $tl; rm -f "$TL.stop"
  cat "$TAC/event.txt"
  # what Clusterware and the surviving instance logged
  $SSH grid@prm1 "grep -hE 'CRS-1601|CRS-1607|CRS-1625|CRS-1632|CRS-1610|CRS-2773|CRS-2771' /u01/app/grid/diag/crs/prm1/crs/trace/alert.log | tail -n 8" | cut -c1-140 | tee "$OUT/maintenance/r10-crs-alert-prm1.txt"
  $SSH oracle@prm1 "grep -hB1 -E 'Instance recovery|Completed redo application|Completed instance recovery|Reconfiguration complete' /u01/app/oracle/diag/rdbms/orcl/orcl1/trace/alert_orcl1.log | tail -n 14" | cut -c1-140 | tee "$OUT/maintenance/r10-instance-recovery-orcl1.txt"
  "$S/dg.sh" prm1 orcl "show configuration" "show fast_start failover" | grep -E 'Primary database|Physical standby|Fast-Start Failover:|^(SUCCESS|WARNING|ERROR)' | tee "$OUT/maintenance/r10-broker-after.txt"
  ;;
back)
  t0=$(date +%s); "${LABCTL:-$HOME/work/lab/labctl.sh}" start prm2 >/dev/null 2>&1
  until timeout 20 $SSH oracle@prm1 '. ~/.bash_profile >/dev/null 2>&1; srvctl status database -db orcl' 2>/dev/null | grep -q 'orcl2 is running'; do sleep 10; [ $(( $(date +%s) - t0 )) -gt 900 ] && { echo "orcl2 not running after 15 min"; exit 1; }; done
  echo "prm2 start (labctl) to orcl2 running: $(( $(date +%s) - t0 )) s" | tee -a "$OUT/maintenance/r10-broker-after.txt"
  # services and GoldenGate stay on prm1, their preferred node: nothing to move back
  $SSH oracle@prm1 '. ~/.bash_profile >/dev/null 2>&1; srvctl status service -db orcl'
  $SSH root@prm1 "$GH/agctl status goldengate GG_A"
  ;;
esac
