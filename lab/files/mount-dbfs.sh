#!/bin/bash
# DBFS mount action script cho GoldenGate deployment (CRS action script / systemd helper)
# Usage: mount-dbfs.sh {start|stop|check|clean}
CONF=/u01/app/oracle/ogg_ha/mount-dbfs.conf
. $CONF                     # ORACLE_HOME, TNS_ADMIN, DBFS_ALIAS, MOUNT_POINT
export ORACLE_HOME TNS_ADMIN LD_LIBRARY_PATH=$ORACLE_HOME/lib
LOG=/u01/app/oracle/ogg_ha/dbfs_client.log

is_mounted() { grep -q " $MOUNT_POINT fuse" /proc/mounts && ls "$MOUNT_POINT/$DBFS_FS" >/dev/null 2>&1; }

case "$1" in
start)
  is_mounted && exit 0
  grep -q " $MOUNT_POINT fuse" /proc/mounts && fusermount -uz "$MOUNT_POINT"
  # File ghi nhầm vào mount point khi DBFS chưa mount: chuyển sang chỗ khác để dbfs_client mount được
  if [ -n "$(ls -A "$MOUNT_POINT" 2>/dev/null)" ]; then
    STRAY=/u01/app/oracle/ogg_ha/stray_$(date +%Y%m%d%H%M%S)
    mkdir -p "$STRAY" && mv "$MOUNT_POINT"/* "$MOUNT_POINT"/.[!.]* "$STRAY"/ 2>/dev/null
    echo "$(date) moved stray files from $MOUNT_POINT to $STRAY" >>$LOG
  fi
  # GG chưa chạy trên node này: xóa file trạng thái process (.pce/.pcr/.s) còn sót từ lần chạy trước
  rm -f /u01/app/oracle/ogg_local/*/run/* 2>/dev/null
  nohup $ORACLE_HOME/bin/dbfs_client /@$DBFS_ALIAS -o wallet,allow_other,direct_io,failover,nolock "$MOUNT_POINT" >>$LOG 2>&1 </dev/null &
  for i in $(seq 1 30); do is_mounted && exit 0; sleep 1; done
  exit 1 ;;
stop)
  fusermount -u "$MOUNT_POINT" 2>/dev/null || { sleep 2; fusermount -uz "$MOUNT_POINT" 2>/dev/null; }
  pkill -f "dbfs_client /@$DBFS_ALIAS" 2>/dev/null
  for i in 1 2 3 4 5; do pgrep -f "dbfs_client /@$DBFS_ALIAS" >/dev/null || break; sleep 1; done
  pkill -9 -f "dbfs_client /@$DBFS_ALIAS" 2>/dev/null
  exit 0 ;;
check)
  # Chỉ dựa vào mount entry: trong lúc role transition PDB đóng tạm thời, ls có thể lỗi;
  # nếu báo OFFLINE lúc đó CRS sẽ không gọi stop và dbfs_client bị bỏ lại trên node cũ.
  grep -q " $MOUNT_POINT fuse" /proc/mounts && exit 0 || exit 1 ;;
clean)
  fusermount -uz "$MOUNT_POINT" 2>/dev/null
  pkill -9 -f "dbfs_client /@$DBFS_ALIAS" 2>/dev/null
  exit 0 ;;
*) echo "Usage: $0 {start|stop|check|clean}"; exit 2 ;;
esac
