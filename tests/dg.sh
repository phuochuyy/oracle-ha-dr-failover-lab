#!/bin/bash
# Credentials come from lab.env at the repo root (see lab.env.example), never from the script.
. "$(cd "$(dirname "$0")/.." && pwd)/lab.env" 2>/dev/null
: "${DGADMIN_PASSWORD_A:?set in lab.env}" "${DGADMIN_PASSWORD_B:?set in lab.env}"
# dg.sh <host> <alias> "<dgmgrl cmd>"...
h=$1 a=$2; shift 2
# as C##DGADMIN (SYSDG only), password on stdin; Region B aliases start with orcl3
case $a in orcl3*) pw=$DGADMIN_PASSWORD_B ;; *) pw=$DGADMIN_PASSWORD_A ;; esac
{ printf 'connect c##dgadmin/"%s"@%s\n' "$pw" "$a"; printf '%s;\n' "$@"; } \
  | ssh -o BatchMode=yes oracle@$h ". ~/.bash_profile >/dev/null 2>&1; dgmgrl -silent" 2>&1 | grep -v '^Connected to'

