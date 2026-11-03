#!/bin/bash
# Run as root on a lab VM (labctl sync_node, after ogg-syslog.conf / ogg-http.logrotate were copied). Idempotent.
# 1) Backups of logrotate configs left in /etc/logrotate.d (*.bak.*) are parsed too -> "duplicate log entry"
#    -> the real /var/log/secure config (daily, compress) was skipped and secure grew to 1.1 GB uncompressed.
mkdir -p /root/logrotate-bak
for f in /etc/logrotate.d/*.bak*; do [ -e "$f" ] && mv -f "$f" /root/logrotate-bak/; done
chmod 644 /etc/rsyslog.d/ogg-http.conf /etc/logrotate.d/ogg-http 2>/dev/null
restorecon -q /etc/rsyslog.d/ogg-http.conf /etc/logrotate.d/ogg-http 2>/dev/null
# 2) GoldenGate REST logging to its own file; keep the old rule if the config does not validate
if rsyslogd -N1 >/dev/null 2>&1; then
  cmp -s /etc/rsyslog.d/ogg-http.conf /root/logrotate-bak/ogg-http.conf.applied || {
    systemctl restart rsyslog && cp /etc/rsyslog.d/ogg-http.conf /root/logrotate-bak/ogg-http.conf.applied; }
else
  echo "rsyslog config invalid - ogg-http.conf removed"; rm -f /etc/rsyslog.d/ogg-http.conf
fi
# 3) Rotated logs that were never compressed (>20 MB): compress, do not delete
find /var/log -maxdepth 1 -type f -regex '.*/\(secure\|messages\)-[0-9]+' -size +20M -exec gzip -f {} \;
# 4) Return freed blocks to the host regularly (sparse images, discard=unmap); fstrim.timer is Persistent
systemctl enable --now fstrim.timer >/dev/null 2>&1
n=$(logrotate -d /etc/logrotate.conf 2>&1 | grep -c '^error')
echo "$(hostname -s): logrotate errors=$n, fstrim.timer=$(systemctl is-enabled fstrim.timer), rsyslog=$(systemctl is-active rsyslog)"
