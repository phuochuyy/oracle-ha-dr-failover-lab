#!/bin/bash
# FAN server-side callout ($GRID_HOME/racg/usrco): start GoldenGate GG_A khi service ogg_a UP.
# XAG --dataguard_autostart dựa vào pullup:always từ service; khi FSFO failover, CRS start service
# với cờ không pullup (Opts 2102, ORA_STATE_HINT=NO_PULLUPS) nên GG_A không tự chạy -> callout bù.
# Service ogg_a chỉ chạy khi DB là PRIMARY, nên sự kiện UP của nó = node này phải chạy GG_A.
# Chạy dưới user của agent (grid/oracle, cùng nhóm oinstall có quyền rwx trên resource XAG).
LOG=/var/tmp/ogg_fan_callout.log
G=/u01/app/23.26.0/grid/bin
RES=xag.GG_A.goldengate

if [ "$1" != "--run" ]; then
  case " $* " in *" service=ogg_a"*) ;; *) exit 0 ;; esac
  case " $* " in *" status=up "*) ;; *) exit 0 ;; esac
  # tách khỏi agent: callout phải trả về ngay, start GG mất 15-30s
  setsid "$0" --run "$@" </dev/null >/dev/null 2>&1 &
  exit 0
fi
shift
exec 9>>/var/tmp/ogg_fan_callout.lock
flock -n 9 || exit 0            # SERVICE và SERVICEMEMBER đến cùng lúc: chỉ một lần start
echo "$(date '+%F %T') $(id -un) event: $*" >> $LOG
sleep 5                         # để thao tác start service của CRS kết thúc trước
if $G/crsctl stat res $RES 2>/dev/null | grep -q "^STATE=ONLINE"; then
  echo "$(date '+%F %T') $RES already ONLINE" >> $LOG
else
  $G/crsctl start resource $RES >> $LOG 2>&1
  echo "$(date '+%F %T') crsctl start $RES rc=$?" >> $LOG
fi
