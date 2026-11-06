#!/bin/bash
# Run once as root on the KVM host: sudo bash host-ntp.sh. Idempotent.
# The VMs have no route to the internet, so the public NTP pool in their chrony.conf was never reachable
# (reach 0, "Not synchronised") and their clocks only followed the host's clock from boot. The host becomes
# their NTP server. It keeps serving when the host itself is offline ("local"), so the VMs stay in step with
# each other, which is what RAC, redo timestamps and GoldenGate latest-timestamp conflict resolution need.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
dpkg -s chrony >/dev/null 2>&1 || apt-get install -y chrony     # replaces systemd-timesyncd on Debian
install -d /etc/chrony/conf.d
cat > /etc/chrony/conf.d/lab-vms.conf <<'CONF'
# Lab VM public networks (Region A and B)
allow 192.168.104.0/24
allow 192.168.105.0/24
allow 192.168.106.0/24
allow 192.168.107.0/24
local stratum 10
CONF
grep -qE '^confdir +/etc/chrony/conf.d' /etc/chrony/chrony.conf || echo 'confdir /etc/chrony/conf.d' >> /etc/chrony/chrony.conf
systemctl enable chrony >/dev/null 2>&1
systemctl restart chrony
sleep 3
chronyc -n tracking | grep -E 'Reference ID|Stratum|Leap status'
ss -lun 'sport = :123' | tail -n +2
