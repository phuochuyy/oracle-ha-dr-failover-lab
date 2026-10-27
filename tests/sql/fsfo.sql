set lines 200
col fs_failover_status for a25
col fs_failover_observer_host for a20
select fs_failover_status, fs_failover_current_target, fs_failover_observer_present, fs_failover_observer_host, protection_level from v$database;
exit
