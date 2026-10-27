#!/bin/bash
# Dọn rác trong VM lab (chạy bằng root). Không đụng datafile, cấu hình, deployment GG.
# Sau khi dọn cần fstrim (disk VM đã bật discard=unmap) để host lấy lại dung lượng.
set -u
used_kb() { df -k --output=used,target / /u02/oradata 2>/dev/null | awk 'NR>1 && !seen[$2]++ {s+=$1} END{print s}'; }
before=$(used_kb)

# OS
dnf clean all -q >/dev/null 2>&1
journalctl --vacuum-size=50M -q 2>/dev/null
find /var/tmp /tmp -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null
rm -f /tmp/ogginst.log /tmp/*.oby /tmp/*.rsp 2>/dev/null

# ADR (trace, incident, cdump, alert cũ hơn 1 ngày) cho grid và oracle
adr_purge() {   # $1=user $2=ORACLE_HOME $3=ADR base
  [ -x $2/bin/adrci ] || return
  homes=$(runuser -u $1 -- env ORACLE_HOME=$2 $2/bin/adrci exec="set base $3; show homes" 2>/dev/null | grep -v "^ADR Homes")
  for h in $homes; do
    runuser -u $1 -- env ORACLE_HOME=$2 $2/bin/adrci exec="set base $3; set home $h; purge -age 1440" >/dev/null 2>&1
  done
}
[ -d /u01/app/23.26.0/grid ] && id grid >/dev/null 2>&1 && adr_purge grid /u01/app/23.26.0/grid /u01/app/grid
adr_purge oracle /u01/app/oracle/product/23.26.0/dbhome_1 /u01/app/oracle

# audit file cũ
find /u01/app/oracle/admin /u01/app/oracle/product/23.26.0/dbhome_1/rdbms/audit \
     /u01/app/23.26.0/grid/rdbms/audit /u01/app/grid/admin -name '*.aud' -mtime +1 -delete 2>/dev/null

# CHM (ora.crf) đã tắt: xóa repository
rm -rf /u01/app/grid/crsdata/*/crf/db/* 2>/dev/null
# core dump / trace output cũ của CRS
find /u01/app/grid/crsdata -path '*/output/*' -type f -mtime +1 -delete 2>/dev/null

# Rác từ quá trình sửa lab
rm -rf /u01/app/oracle/ogg_ha/backup /u01/app/oracle/ogg_ha/stray_* 2>/dev/null
rm -f /u01/app/oracle/product/23.26.0/dbhome_1/network/admin/*.bak.* 2>/dev/null
: > /u01/app/oracle/ogg_ha/dbfs_client.log 2>/dev/null
# Bộ cài GoldenGate (đã cài xong trên mọi node; người dùng yêu cầu xóa)
rm -f /home/oracle/V1054774-01.zip 2>/dev/null

# Archivelog cũ hơn 1 ngày (RMAN giữ lại log mà standby/GoldenGate capture còn cần)
sid=$(pgrep -a -f '^ora_pmon_' | awk '{print $2}' | sed 's/ora_pmon_//' | head -1)
if [ -n "$sid" ]; then
  runuser -u oracle -- env ORACLE_HOME=/u01/app/oracle/product/23.26.0/dbhome_1 ORACLE_SID=$sid \
    /u01/app/oracle/product/23.26.0/dbhome_1/bin/rman target / >/dev/null 2>&1 <<'RMAN'
crosscheck archivelog all;
delete noprompt expired archivelog all;
delete noprompt archivelog all completed before 'sysdate-1';
RMAN
fi

after=$(used_kb)
echo "$(hostname -s): freed $(( (before-after)/1024 )) MB inside VM"
