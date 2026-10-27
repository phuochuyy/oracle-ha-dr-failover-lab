#!/bin/bash
# Delete the archived logs that the RMAN deletion policy allows (APPLIED ON ALL STANDBY; on the
# primary RMAN also keeps logs a GoldenGate capture still needs). Needed because the FRA did not
# reclaim applied logs by itself and the 10 GB standby FRA filled up twice (ORA-19809).
# Run by arch-housekeeping.timer as oracle on prm3 / stb3. Log: ~/arch-housekeeping.log
. ~/.bash_profile >/dev/null 2>&1
LOG=$HOME/arch-housekeeping.log
pgrep -f "ora_pmon_${ORACLE_SID}\$" >/dev/null || exit 0
out=$(printf "delete noprompt archivelog all;\nexit\n" | rman target / 2>&1)
n=$(echo "$out" | grep -oE "Deleted [0-9]+ objects" | grep -oE "[0-9]+")
fra=$(printf "set heading off feedback off\nselect round(space_used/1048576)||'/'||round(space_limit/1048576)||'MB' from v\$recovery_file_dest;\nexit\n" \
      | sqlplus -s / as sysdba | tr -d ' \n')
echo "$(date '+%F %T') deleted=${n:-0} fra=$fra $(echo "$out" | grep -oE 'RMAN-[0-9]+' | sort | uniq -c | tr -s ' \n' ' ')" >> "$LOG"
