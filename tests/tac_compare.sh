#!/bin/bash
# Run the two clients side by side through one event: both see the same outage.
# usage (from the host): tests/tac_compare.sh <out dir> <seconds> <seconds before event> <event command...>
# The event runs after the delay, its start and end time go to event.txt; each client's log has one line per transaction.
set -u
S=$(cd "$(dirname "$0")" && pwd)
. "$S/../lab.env"; : "${TAC_APP_PASSWORD:?set in lab.env}"; export TAC_APP_PASSWORD
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-$HOME/work/tools/instantclient_23_26}
PY=${PY:-$HOME/work/tools/venvs/dba/bin/python}
out=$1 secs=$2 delay=$3; shift 3; mkdir -p "$out"
for s in bank_app bank_plain; do "$PY" -I "$S/tac_client.py" "$s" "$secs" "$out/$s.log" > "$out/$s.out" 2>&1 & done
sleep "$delay"
{ echo "event start $(date +%T.%3N): $*"; "$@"; echo "event end $(date +%T.%3N) rc=$?"; } > "$out/event.txt" 2>&1
wait
cat "$out"/bank_app.out "$out"/bank_plain.out | cut -c1-210
