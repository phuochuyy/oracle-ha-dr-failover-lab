#!/bin/bash
# Credentials come from lab.env at the repo root (see lab.env.example), never from the script.
. "$(cd "$(dirname "$0")/.." && pwd)/lab.env" 2>/dev/null
: "${DGADMIN_PASSWORD_A:?set in lab.env}" "${DGADMIN_PASSWORD_B:?set in lab.env}" "${OGG_PASSWORD:?set in lab.env}" "${APP_PASSWORD:?set in lab.env}"
# gg.sh <host> <deployment> "<adminclient cmd>" ["<cmd>"...]
h=$1 d=$2; shift 2
{ echo "CONNECT http://localhost:9100 DEPLOYMENT $d AS oggadmin PASSWORD ${OGG_PASSWORD}"; printf '%s\n' "$@"; } \
 | ssh -o BatchMode=yes oracle@$h 'cat > /tmp/c.oby; /u01/app/gg/bin/adminclient -O /tmp/c.oby 2>&1 | grep -vE "^(Oracle GoldenGate Admin|Version |Copyright|Linux, x64|Operating system|Using default|Using \x27|Connecting|$)"; rm -f /tmp/c.oby'
