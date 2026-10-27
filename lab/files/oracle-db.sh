#!/bin/bash
# Start/stop listener + single-instance DB (không có Oracle Restart)
export ORACLE_HOME=/u01/app/oracle/product/23.26.0/dbhome_1 ORACLE_SID=ORCL3 PATH=/u01/app/oracle/product/23.26.0/dbhome_1/bin:$PATH
case "$1" in
start) lsnrctl start >/dev/null
       echo "startup" | sqlplus -s / as sysdba ;;
stop)  echo "shutdown immediate" | sqlplus -s / as sysdba
       lsnrctl stop >/dev/null ;;
esac
