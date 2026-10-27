-- Safe cleanup (see tests/README.md): only run after the workload is stopped, both
-- Replicats have read past the last change, and the local Replicat is STOPPED.
alter session set ddl_lock_timeout=120;
exec dbms_goldengate_adm.remove_auto_cdr('APP','TXN')
drop table app.txn purge;
