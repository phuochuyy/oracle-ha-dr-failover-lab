-- Test table for the Active-Active failover tests. Run as SYSDBA in each PDB
-- (ORCLPDB2 on Region A, GGREPL on Region B). DDL is NOT replicated: create on both sides.
-- PK (site, seq) makes rows written at the two sites never collide.
create table app.txn (
  site    varchar2(4)  not null,
  seq     number       not null,
  phase   varchar2(20) not null,
  created timestamp default systimestamp not null,
  constraint txn_pk primary key (site, seq));
exec dbms_goldengate_adm.add_auto_cdr('APP','TXN')
