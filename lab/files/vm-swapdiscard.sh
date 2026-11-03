#!/bin/bash
# Run as root on a lab VM. Idempotent.
# The VM disks are sparse images: a swap block written once stays allocated on the host, and fstrim does
# not touch swap (LV ol-swap and /swapfile). With "discard" on the swap entries the kernel discards the
# whole area at swapon and freed pages while running (also at swapoff on shutdown) -> host space returns.
# Never blkdiscard a swap device: it wipes the swap header (swapon then fails until mkswap).
set -u
f=/etc/fstab
if awk '$0 !~ /^[[:space:]]*#/ && $3 == "swap" && $4 !~ /discard/ {found=1} END {exit !found}' $f; then
  [ -e /root/fstab.bak_swapdiscard ] || cp -p $f /root/fstab.bak_swapdiscard
  awk 'BEGIN {OFS="\t"} $0 !~ /^[[:space:]]*#/ && $3 == "swap" && $4 !~ /discard/ {$4 = $4 ",discard"} {print}' $f > $f.new \
    && chmod --reference=$f $f.new && chown --reference=$f $f.new && mv -f $f.new $f
  restorecon -q $f 2>/dev/null
  systemctl daemon-reload
fi
# discard now if swap is nearly empty and RAM can take it back (right after boot); otherwise next boot does it
used=$(awk 'NR > 1 {s += $4} END {print int(s / 1024)}' /proc/swaps)        # MB
avail=$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)            # MB
if [ "$used" -le 500 ] && [ "$avail" -gt $((used * 3 + 500)) ]; then
  swapoff -a && swapon -a && now="discarded now (was $used MB used)"
else
  now="not now ($used MB used, $avail MB available) - at next boot"
fi
n=$(swapon --show=NAME --noheadings | wc -l); e=$(awk '$0 !~ /^[[:space:]]*#/ && $3 == "swap"' $f | wc -l)
echo "$(hostname -s): swap entries with discard $(awk '$0 !~ /^[[:space:]]*#/ && $3 == "swap" && $4 ~ /discard/' $f | wc -l)/$e, active $n/$e, $now"
