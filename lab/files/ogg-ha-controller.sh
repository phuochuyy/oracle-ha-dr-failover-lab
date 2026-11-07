#!/bin/bash
# GoldenGate HA controller cho node không có Grid Infrastructure (thay vai trò XAG).
# Chạy GG (DBFS + Service Manager + NGINX) chỉ khi database local là PRIMARY / READ WRITE.
ORACLE_HOME=/u01/app/oracle/product/23.26.0/dbhome_1
ORACLE_SID=ORCL3
OGG_HOME=/u01/app/gg
OGG_ETC_HOME=/mnt/dbfs/ogg/sm/etc
OGG_VAR_HOME=/mnt/dbfs/ogg/sm/var
MOUNT=/u01/app/oracle/ogg_ha/mount-dbfs.sh
INTERVAL=15
GG_PROCS="ServiceManager adminsrvr distsrvr recvsrvr pmsrvr AIService"

log() { echo "$(date '+%F %T') $*"; }

db_state() {
  runuser -u oracle -- env ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$ORACLE_SID \
    $ORACLE_HOME/bin/sqlplus -s -L / as sysdba <<'SQL' 2>/dev/null | tr -d ' \n'
set heading off feedback off pages 0
select database_role||':'||open_mode from v$database;
SQL
}

gg_running() { pgrep -u oracle -x ServiceManager >/dev/null; }

start_gg() {
  runuser -u oracle -- $MOUNT start || { log "DBFS mount failed"; return 1; }
  if ! gg_running; then
    log "starting Service Manager"
    runuser -u oracle -- env OGG_HOME=$OGG_HOME OGG_ETC_HOME=$OGG_ETC_HOME OGG_VAR_HOME=$OGG_VAR_HOME \
      setsid nohup $OGG_HOME/bin/ServiceManager >/dev/null 2>&1 </dev/null &
  fi
  systemctl is-active -q nginx || systemctl start nginx
  gg_running && watch_ports
  # đồng bộ target distribution path mỗi ~60s
  if gg_running && [ $(( $(date +%s) / 60 )) -ne "${LAST_SYNC:-0}" ]; then
    LAST_SYNC=$(( $(date +%s) / 60 ))
    runuser -u oracle -- /u01/app/oracle/ogg_ha/ogg-path-sync.py start
  fi
}

# A service can start and fail to load its configuration from DBFS (OGG-12009 on stb3, right after a role change): the
# process stays alive with no port open, INFO ALL says RUNNING, and the Service Manager leaves it alone. The path then
# stops with nothing reporting it. Killed, it is relaunched by the Service Manager and comes up in seconds.
watch_ports() {
  local x pid age
  for x in "adminsrvr 9101" "distsrvr 9102" "recvsrvr 9103"; do
    set -- $x
    pid=$(pgrep -u oracle -x "$1") || continue
    ss -ltn | grep -q ":$2 " && continue
    age=$(ps -o etimes= -p "$pid" | tr -d ' ')
    if [ "${age:-0}" -gt 60 ]; then
      log "$1 pid $pid: up $age s, port $2 closed: killing it, the Service Manager relaunches it"
      kill "$pid"
    fi
  done
}

stop_gg() {
  if gg_running || pgrep -u oracle -x extract >/dev/null || pgrep -u oracle -x replicat >/dev/null; then
    log "stopping GoldenGate"
    for p in extract replicat $GG_PROCS; do pkill -u oracle -x $p; done
    sleep 10
    for p in extract replicat $GG_PROCS; do pkill -9 -u oracle -x $p; done
  fi
  systemctl is-active -q nginx && systemctl stop nginx
  runuser -u oracle -- $MOUNT check && { log "unmounting DBFS"; runuser -u oracle -- $MOUNT stop; }
}

trap 'stop_gg; exit 0' TERM INT
log "controller started"
while true; do
  st=$(db_state)
  case "$st" in
    PRIMARY:READWRITE) start_gg ;;
    *) stop_gg ;;
  esac
  sleep $INTERVAL &
  wait $!
done
