#!/bin/bash
# Credentials come from lab.env at the repo root (see lab.env.example), never from the script.
. "$(cd "$(dirname "$0")/.." && pwd)/lab.env" 2>/dev/null
: "${DB_PASSWORD:?set in lab.env}" "${OGG_PASSWORD:?set in lab.env}" "${APP_PASSWORD:?set in lab.env}"
# dg.sh <host> <alias> "<dgmgrl cmd>"...
h=$1 a=$2; shift 2
printf '%s;\n' "$@" | ssh -o BatchMode=yes oracle@$h ". ~/.bash_profile >/dev/null 2>&1; dgmgrl -silent sys/${DB_PASSWORD}@$a" 2>&1
