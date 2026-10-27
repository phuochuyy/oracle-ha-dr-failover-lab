#!/bin/bash
# Điều khiển lab Oracle HA/DR theo kịch bản.
# Host 23 GB RAM: VM RAC 7 GB, single-instance 5 GB, observer 1 GB -> mỗi cụm RAC chạy 1 node.
#
#   ./labctl.sh status     trạng thái VM, Data Guard, GoldenGate
#   ./labctl.sh gg         GoldenGate Active-Active:        prm1 + prm3                   (~12 GB)
#   ./labctl.sh dg-a       Region A (ADG + FSFO):           prm1 + stb1 + obs-r1 + prm3   (~20 GB)
#   ./labctl.sh dg-b       Region B (ADG + FSFO):           prm3 + stb3 + obs-r2 + prm1   (~20 GB)
#   ./labctl.sh rac        RAC 2 node (test relocate XAG):  prm1 + prm2 + prm3            (~19 GB)
#   ./labctl.sh stop-all   tắt toàn bộ lab an toàn
#
# Region có standby tắt: tắt FSFO + TRANSPORT-OFF + bỏ HANDLEDLFAILOVER (theo khuyến nghị của Oracle khi standby ngừng lâu).
# Region có standby chạy: TRANSPORT-ON, chờ đồng bộ, bật FSFO + HANDLEDLFAILOVER.

set -u
LAB=$(cd "$(dirname "$0")" && pwd)
F=$LAB/files
VIRSH="virsh -c qemu:///system"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
SCP="scp -q -o BatchMode=yes"
G=/u01/app/23.26.0/grid/bin
HA=/u01/app/oracle/ogg_ha
# Credentials come from lab.env at the repo root (see lab.env.example), never from the script.
. "$(cd "$(dirname "$0")/.." && pwd)/lab.env" 2>/dev/null
: "${DB_PASSWORD:?set in lab.env}" "${OGG_PASSWORD:?set in lab.env}" "${APP_PASSWORD:?set in lab.env}"
DGPW="$DB_PASSWORD"

log() { echo "[$(date +%T)] $*"; }
running() { [ "$($VIRSH domstate "$1" 2>/dev/null | head -1)" = "running" ]; }

# ---------------------------------------------------------------- VM
vm_start() {
  local v
  for v in "$@"; do running $v || { log "start VM $v"; $VIRSH start "$v" >/dev/null; }; done
  for v in "$@"; do
    for i in $(seq 1 60); do $SSH root@$v true 2>/dev/null && break; sleep 5; done
    sync_node $v
  done
}

vm_stop() {
  local v
  for v in "$@"; do
    running $v || continue
    case $v in
      prm3|stb3)           $SSH root@$v 'systemctl stop ogg-ha oracle-db' 2>/dev/null ;;
      prm1|prm2|stb1|stb2)
        # Phải dừng CRS hoàn toàn trước khi tắt OS; nếu không CSS chết đột ngột -> cssdagent reboot node.
        # Dừng lỗi khi CRS đang khởi động dở -> thử lại đến khi OHAS dừng hẳn.
        for i in $(seq 1 10); do
          $SSH root@$v "timeout 300 $G/crsctl stop crs -f" >/dev/null 2>&1
          $SSH root@$v "$G/crsctl check has" 2>&1 | grep -q "CRS-4639" && break
          sleep 20
        done ;;
    esac
    log "shutdown VM $v"; $VIRSH shutdown "$v" >/dev/null
  done
  for v in "$@"; do
    for i in $(seq 1 60); do running $v || break; sleep 5; done
    # if/fi, not "running && ...": a VM that is already off must not make the function return 1
    if running $v; then log "force off $v"; $VIRSH destroy "$v" >/dev/null; fi
  done
}

# Đồng bộ file cấu hình HA/GG (bản chuẩn nằm trong $F) sang node vừa bật
sync_node() {
  local v=$1 r
  case $v in
    prm1|prm2|stb1|stb2) r=A ;;
    prm3|stb3)           r=B ;;
    *) return ;;
  esac
  $SCP $F/mount-dbfs.sh $F/ogg-path-sync.py oracle@$v:$HA/
  sed "s/^OGG_PASSWORD=.*/OGG_PASSWORD=$OGG_PASSWORD/" $F/pathsync_$(echo $r | tr A-Z a-z).conf.example \
    | $SSH oracle@$v "umask 077; cat > $HA/pathsync.conf"
  $SSH root@$v "chmod 750 $HA/mount-dbfs.sh $HA/ogg-path-sync.py; chmod 600 $HA/pathsync.conf
    printf 'd /run/ogg 0750 oracle oinstall -\nd /run/ogg/GG_$r 0750 oracle oinstall -\nd /run/ogg/sm 0750 oracle oinstall -\n' > /etc/tmpfiles.d/ogg.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/ogg.conf
    for x in GG_$r sm; do mkdir -p /u01/app/oracle/ogg_local/\$x/temp /u01/app/oracle/ogg_local/\$x/lock
      L=/u01/app/oracle/ogg_local/\$x/run; [ -L \$L ] || { rm -rf \$L; ln -s /run/ogg/\$x \$L; }; done
    chown -R oracle:oinstall /u01/app/oracle/ogg_local" 2>/dev/null
  if [ $r = A ]; then
    # FAN callout: start GG_A sau FSFO failover (XAG không được pullup trong trường hợp này)
    $SCP $F/ogg-fan-callout.sh root@$v:/u01/app/23.26.0/grid/racg/usrco/ogg-fan-callout.sh
    $SSH root@$v "chown grid:oinstall /u01/app/23.26.0/grid/racg/usrco/ogg-fan-callout.sh; chmod 755 /u01/app/23.26.0/grid/racg/usrco/ogg-fan-callout.sh
      for f in /var/tmp/ogg_fan_callout.log /var/tmp/ogg_fan_callout.lock; do touch \$f; chmod 666 \$f; done" 2>/dev/null
    # CHM không cần cho lab, tốn ~200 MB RAM mỗi node
    $SSH root@$v "$G/crsctl modify res ora.crf -attr ENABLED=0 -init >/dev/null 2>&1; $G/crsctl stop res ora.crf -init >/dev/null 2>&1" &
  else
    $SCP $F/ogg-ha-controller.sh root@$v:$HA/ogg-ha-controller.sh.new
    $SCP $F/ogg-ha.service $F/oracle-db.service $F/arch-housekeeping.service $F/arch-housekeeping.timer root@$v:/etc/systemd/system/
    $SCP $F/arch-housekeeping.sh root@$v:$HA/
    $SSH root@$v "chown oracle:oinstall $HA/arch-housekeeping.sh; chmod 750 $HA/arch-housekeeping.sh" 2>/dev/null
    $SSH root@$v "systemctl daemon-reload; cd $HA; chown root:oinstall ogg-ha-controller.sh.new; chmod 750 ogg-ha-controller.sh.new
      cmp -s ogg-ha-controller.sh.new ogg-ha-controller.sh && rm -f ogg-ha-controller.sh.new || { mv -f ogg-ha-controller.sh.new ogg-ha-controller.sh; systemctl restart ogg-ha; }" 2>/dev/null
    $SSH root@$v "systemctl enable --now arch-housekeeping.timer" >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------- Data Guard
dg() {   # dg A|B lệnh...  (chạy dgmgrl trên node đang bật của region)
  local r=$1 host alias; shift
  if [ $r = A ]; then alias=orcl; for host in prm1 prm2 stb1 stb2; do running $host && break; done
  else alias=orcl3; for host in prm3 stb3; do running $host && break; done; fi
  printf '%s;\n' "$@" | $SSH oracle@$host ". ~/.bash_profile >/dev/null 2>&1; dgmgrl -silent sys/$DGPW@$alias" 2>&1
}

dg_isolate() {
  local r=$1 p; [ $r = A ] && p=orcl || p=orcl3
  log "Region $r: disable FSFO, TRANSPORT-OFF, HANDLEDLFAILOVER off"
  dg $r "disable fast_start failover force" "edit database $p set state='TRANSPORT-OFF'" >/dev/null
  gg_hdl $r off
}

dg_protect() {
  local r=$1 p s; [ $r = A ] && { p=orcl; s=orcl_stb; } || { p=orcl3; s=ORCL3_STB; }
  log "Region $r: TRANSPORT-ON, APPLY-ON"
  # Primary vừa boot có thể chưa open: lệnh edit không có hiệu lực -> lặp đến khi broker nhận TRANSPORT-ON
  for i in $(seq 1 60); do
    dg $r "enable database $s" "edit database $p set state='TRANSPORT-ON'" "edit database $s set state='APPLY-ON'" >/dev/null
    dg $r "show database $p" | grep -q "Intended State: *TRANSPORT-ON" && break
    sleep 10
  done
  for i in $(seq 1 60); do dg $r "show configuration" | grep -q "^SUCCESS" && break; sleep 10; done
  log "Region $r: enable FSFO, HANDLEDLFAILOVER on"
  dg $r "enable fast_start failover" | grep -vE "^Connected|^$"
  for i in $(seq 1 60); do [ -n "$(gg_node $r)" ] && break; sleep 10; done   # gg_hdl cần deployment đang chạy
  gg_hdl $r on
}

# ---------------------------------------------------------------- GoldenGate
gg_node() {   # node đang chạy deployment của region
  local h
  if [ $1 = A ]; then
    for h in prm1 prm2 stb1 stb2; do running $h || continue
      $SSH root@$h "$G/agctl status goldengate GG_A" 2>/dev/null | grep -oE "running on [a-z0-9]+" | awk '{print $3}'; return; done
  else
    for h in prm3 stb3; do running $h && $SSH root@$h 'pgrep -x ServiceManager' >/dev/null 2>&1 && { echo $h; return; }; done
  fi
}

gg_hdl() {    # bật/tắt TRANLOGOPTIONS HANDLEDLFAILOVER của Extract region
  local r=$1 mode=$2 n d e prm
  n=$(gg_node $r); [ -z "$n" ] && return
  d=GG_$r; e=EXT$r; prm=/mnt/dbfs/ogg/$d/etc/conf/ogg/$(echo $e | tr A-Z a-z).prm
  if [ $mode = on ]; then
    $SSH oracle@$n "grep -q '^-- TRANLOGOPTIONS HANDLEDLFAILOVER' $prm" || return
    $SSH oracle@$n "sed -i 's/^-- TRANLOGOPTIONS HANDLEDLFAILOVER/TRANLOGOPTIONS HANDLEDLFAILOVER/' $prm"
  else
    $SSH oracle@$n "grep -q '^TRANLOGOPTIONS HANDLEDLFAILOVER' $prm" || return
    $SSH oracle@$n "sed -i 's/^TRANLOGOPTIONS HANDLEDLFAILOVER/-- TRANLOGOPTIONS HANDLEDLFAILOVER/' $prm"
  fi
  local c="CONNECT http://localhost:9100 DEPLOYMENT $d AS oggadmin PASSWORD $OGG_PASSWORD"
  ggc() { printf "$c\n%s\n" "$1" | $SSH oracle@$n "cat > /tmp/hdl.oby; /u01/app/gg/bin/adminclient -O /tmp/hdl.oby 2>&1; rm -f /tmp/hdl.oby"; }
  ggc "STOP EXTRACT $e" >/dev/null
  # STOP trả về trước khi Extract dừng hẳn; START gửi ngay lúc đó bị bỏ qua -> Extract nằm STOPPED
  for i in $(seq 1 30); do ggc "INFO EXTRACT $e" | grep -q "Status STOPPED" && break; sleep 2; done
  ggc "START EXTRACT $e" >/dev/null
}

gg_status() {
  local r n
  for r in A B; do
    n=$(gg_node $r); [ -z "$n" ] && { echo "   GG_$r: không chạy"; continue; }
    printf "CONNECT http://localhost:9100 DEPLOYMENT GG_$r AS oggadmin PASSWORD $OGG_PASSWORD\nINFO ALL\nINFO DISTPATH ALL\n" \
      | $SSH oracle@$n "cat > /tmp/st.oby; /u01/app/gg/bin/adminclient -O /tmp/st.oby 2>&1; rm -f /tmp/st.oby" \
      | grep -E "EXTRACT |REPLICAT |^ [A-Z0-9]+2[A-Z]" | sed "s/^/   GG_$r@$n  /"
  done
}

status() {
  echo "== VMs"; $VIRSH list --all | sed '1,2d;/^$/d'
  for r in A B; do
    echo "== Data Guard region $r"
    dg $r "show configuration" "show fast_start failover" 2>/dev/null \
      | grep -E "Primary database|Physical standby|Fast-Start Failover:|Observer:|^(SUCCESS|WARNING|ERROR)" | sed 's/^/   /'
  done
  echo "== GoldenGate"; gg_status
}

case "${1:-status}" in
  status)   status ;;
  gg)       vm_start prm1 prm3
            dg_isolate A; dg_isolate B
            vm_stop prm2 stb1 stb2 stb3 obs-r1 obs-r2
            status ;;
  dg-a)     dg_isolate B 2>/dev/null
            vm_stop prm2 stb2 stb3 obs-r2
            vm_start prm1 prm3 stb1 obs-r1
            dg_protect A
            $SSH root@stb1 bash -s < $F/crs_pathsync.sh >/dev/null 2>&1   # idempotent
            status ;;
  dg-b)     dg_isolate A 2>/dev/null
            vm_stop prm2 stb1 stb2 obs-r1
            vm_start prm1 prm3 stb3 obs-r2
            dg_protect B
            status ;;
  rac)      dg_isolate A 2>/dev/null; dg_isolate B 2>/dev/null
            vm_stop stb1 stb2 stb3 obs-r1 obs-r2
            vm_start prm1 prm2 prm3
            status ;;
  stop-all) dg_isolate A 2>/dev/null; dg_isolate B 2>/dev/null
            vm_stop obs-r1 obs-r2 stb1 stb2 stb3 prm3 prm2 prm1 ;;
  trim)     # Dọn rác + fstrim từng VM để host lấy lại dung lượng (disk đã bật discard=unmap).
            # Chạy lần lượt từng VM một (RAM). Kết thúc: toàn bộ lab tắt.
            dg_isolate A 2>/dev/null; dg_isolate B 2>/dev/null
            vm_stop obs-r1 obs-r2 stb1 stb2 stb3 prm3 prm2 prm1
            for v in ${2:-obs-r1 obs-r2 stb3 prm3 stb2 stb1 prm2 prm1}; do
              vm_start $v
              case $v in prm*|stb*) for i in $(seq 1 60); do
                  $SSH root@$v "pgrep -f '^ora_pmon_'" >/dev/null 2>&1 && break; sleep 10; done ;; esac
              $SSH root@$v bash -s < $F/vm-cleanup.sh
              $SSH root@$v 'fstrim -a' 2>/dev/null
              vm_stop $v
              log "host: $(df -h / | awk 'NR==2{print $4" free"}')"
            done ;;
  *)        sed -n '2,13p' "$0"; exit 2 ;;
esac
