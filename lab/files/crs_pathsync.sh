G=/u01/app/23.26.0/grid/bin
$G/crsctl stat res ogg_pathsync 2>/dev/null | grep -q "^NAME=ogg_pathsync" && exit 0
$G/crsctl add resource ogg_pathsync -type cluster_resource -attr "ACTION_SCRIPT=/u01/app/oracle/ogg_ha/ogg-path-sync.py,CHECK_INTERVAL=60,SCRIPT_TIMEOUT=120,RESTART_ATTEMPTS=3,START_DEPENDENCIES='hard(xag.GG_A.goldengate)pullup(xag.GG_A.goldengate)',STOP_DEPENDENCIES='hard(xag.GG_A.goldengate)',ACL='owner:oracle:rwx,pgrp:oinstall:rwx,other::r--'"
$G/crsctl setperm resource ogg_pathsync -o oracle
$G/crsctl start res ogg_pathsync
$G/crsctl stat res ogg_pathsync -t | grep -E "ONLINE|OFFLINE"
