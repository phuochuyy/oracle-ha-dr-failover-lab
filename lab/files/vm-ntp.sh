#!/bin/bash
# Run as root on a lab VM: bash -s < vm-ntp.sh. Idempotent. Called by labctl at every start.
# Points chrony at the KVM host (the VM's default gateway, see host-ntp.sh). Prints one status line.
# The old file is kept in /root: a backup copy must not sit next to live configuration.
set -u
f=/etc/chrony.conf
gw=$(ip route | awk '/^default/ {print $3; exit}')
[ -n "$gw" ] || { echo "ntp: no default route, chrony.conf unchanged"; exit 0; }
want="server $gw iburst"
if [ "$(grep -E '^(pool|server)[[:space:]]' $f)" = "$want" ]; then
  action="conf ok"
else
  [ -e /root/chrony.conf.bak_vmntp ] || cp -p $f /root/chrony.conf.bak_vmntp
  if { echo "$want"; grep -vE '^(pool|server)[[:space:]]' $f; } > $f.new \
     && chmod --reference=$f $f.new && chown --reference=$f $f.new && mv -f $f.new $f; then
    restorecon -q $f 2>/dev/null
    systemctl restart chronyd
    action="conf installed"
  else
    rm -f $f.new
    action="conf write FAILED"
  fi
fi
systemctl enable --now chronyd >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do
  chronyc -n tracking 2>/dev/null | grep -q 'Leap status *: *Normal' && break
  sleep 2
done
echo "ntp: $action, $(chronyc -n tracking 2>/dev/null | awk -F': ' '/^Leap status/ {l=$2} /^System time/ {t=$2} END {print l", "t}')"
