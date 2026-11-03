#!/bin/bash
# Run as root on a Region A RAC node (prm1, prm2, stb1, stb2): bash -s <desired sqlnet.ora> < vm-nne.sh. Idempotent.
# Native network encryption was applied by hand on prm1/stb1 only; prm2/stb2 were off and stayed unencrypted.
# Now every boot through labctl makes the node match:
#   - database home sqlnet.ora = files/nne-sqlnet.ora (AES256 + SHA256 REQUIRED, logon version 12a).
#     Read by every new server process: no restart needed. The old file is kept as *.bak_<time>.
#   - grid listener.ora has ADMIN_RESTRICTIONS_LISTENER=ON (reload if the listener is already up;
#     otherwise it reads the file when CRS starts it).
set -u
src=${1:?usage: vm-nne.sh <desired sqlnet.ora>}
DBH=/u01/app/oracle/product/23.26.0/dbhome_1 GH=/u01/app/23.26.0/grid
f=$DBH/network/admin/sqlnet.ora l=$GH/network/admin/listener.ora
ts=$(date +%Y%m%d_%H%M)
if cmp -s "$src" "$f"; then out="sqlnet.ora ok"
else
  [ -f "$f" ] && cp -p "$f" "$f.bak_$ts"
  install -o oracle -g oinstall -m 644 "$src" "$f" && out="sqlnet.ora installed" || out="sqlnet.ora FAILED"
fi
rm -f "$src"
if [ ! -f "$l" ]; then out="$out, listener.ora missing"
elif grep -qE '^ADMIN_RESTRICTIONS_LISTENER *= *ON' "$l"; then out="$out, listener ok"
else
  cp -p "$l" "$l.bak_$ts"
  echo 'ADMIN_RESTRICTIONS_LISTENER=ON' >> "$l"
  if su - grid -c "lsnrctl reload LISTENER" 2>&1 | grep -q 'completed successfully'; then
    out="$out, listener restricted + reloaded"
  else out="$out, listener restricted (not running yet, read at start)"; fi
fi
echo "$out"
