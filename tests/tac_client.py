#!/usr/bin/env python3
"""Application client for the Application Continuity test: what does the application see during a role change?

Each transaction: insert (step 1), wait, insert (step 2), commit, on one pooled session. The wait keeps a transaction
in flight most of the time, so an outage is likely to hit one. Seq is chosen by the client and the table has no unique
key, so a transaction replayed twice would show up as extra rows.

The log has one line per transaction. At the end the client compares what it was told with what is in the database:
  told OK, rows missing -> lost        told OK, more than 2 rows -> duplicated
  told error, rows there -> committed but the application was told it failed (the case Transaction Guard exists for)

usage: TAC_APP_PASSWORD=... tac_client.py <bank_app|bank_plain> <seconds> <log file>
"""
import datetime as dt
import os
import pathlib
import sys
import time

import oracledb

SCAN_A = ("192.168.104.14", "192.168.104.15", "192.168.104.16")
SCAN_B = ("192.168.105.14", "192.168.105.15", "192.168.105.16")
IC = pathlib.Path("~/work/tools/instantclient_23_26").expanduser()
THINK = 0.3


def addr_list(ips):
    return "(ADDRESS_LIST=(LOAD_BALANCE=ON)" + "".join(f"(ADDRESS=(PROTOCOL=TCP)(HOST={i})(PORT=1521))" for i in ips) + ")"


def descriptor(service):
    # Oracle's recommended form for a client of a RAC + Data Guard pair: both SCANs, enough retries to outlast a role change
    return ("(DESCRIPTION=(CONNECT_TIMEOUT=90)(RETRY_COUNT=30)(RETRY_DELAY=3)(TRANSPORT_CONNECT_TIMEOUT=3)(EXPIRE_TIME=1)"
            + addr_list(SCAN_A) + addr_list(SCAN_B) + f"(CONNECT_DATA=(SERVICE_NAME={service}.rac)))")


def now():
    return dt.datetime.now().strftime("%H:%M:%S.%f")[:-3]


def main():
    service, seconds, logname = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    oracledb.init_oracle_client(lib_dir=str(IC), config_dir=str(pathlib.Path(__file__).resolve().parent / "tac_net"))
    pw = os.environ["TAC_APP_PASSWORD"]
    dsn = descriptor(service)
    pool = oracledb.create_pool(user="tac_app", password=pw, dsn=dsn, min=1, max=1, increment=0,
                                events=service == "bank_app", getmode=oracledb.POOL_GETMODE_WAIT)
    client = f"{service[5:]}{int(time.time()) % 100000}"[:12]
    told = {}
    slowest = (0.0, None)
    with open(logname, "w", buffering=1) as log:
        log.write(f"# client={client} service={service} think={THINK}s start={now()}\n")
        seq, end = 0, time.time() + seconds
        while time.time() < end:
            seq += 1
            t0 = time.time()
            try:
                with pool.acquire() as c:
                    with c.cursor() as cur:
                        ins = ("insert into tac_app.txn_log (client, seq, step, inst) values "
                               "(:1, :2, :3, sys_context('userenv', 'instance_name'))")
                        cur.execute(ins, [client, seq, 1])
                        time.sleep(THINK)
                        cur.execute(ins, [client, seq, 2])
                        c.commit()
                        cur.execute("select sys_context('userenv', 'instance_name') from dual")
                        inst = cur.fetchone()[0]
                ms = (time.time() - t0) * 1000
                told[seq] = "OK"
                if ms > slowest[0]:
                    slowest = (ms, seq)
                log.write(f"{now()} {seq} OK {inst} {ms:.0f}\n")
            except oracledb.Error as e:
                code = str(e).split(":")[0].strip()
                told[seq] = "ERR"
                log.write(f"{now()} {seq} ERR {code} {(time.time() - t0) * 1000:.0f}\n")
                time.sleep(1)
    # compare, on a fresh connection that may have to wait for the new primary
    conn = oracledb.connect(user="tac_app", password=pw, dsn=dsn)
    with conn.cursor() as cur:
        cur.execute("select seq, count(*) from tac_app.txn_log where client = :1 group by seq", [client])
        rows = dict(cur.fetchall())
    ok = sum(1 for v in told.values() if v == "OK")
    err = len(told) - ok
    lost = [s for s, v in told.items() if v == "OK" and rows.get(s, 0) < 2]
    dup = [s for s, n in rows.items() if n > 2]
    told_err_committed = [s for s, v in told.items() if v == "ERR" and rows.get(s, 0) >= 2]
    told_err_partial = [s for s, v in told.items() if v == "ERR" and rows.get(s, 0) == 1]
    summary = (f"# summary client={client} service={service} transactions={len(told)} told_ok={ok} errors_seen={err} "
               f"lost={len(lost)} duplicated={len(dup)} error_but_committed={len(told_err_committed)} partial={len(told_err_partial)} "
               f"slowest_ok_ms={slowest[0]:.0f} (seq {slowest[1]})")
    with open(logname, "a") as log:
        log.write(summary + "\n")
    print(summary, flush=True)
    return 1 if lost or dup or told_err_partial else 0


if __name__ == "__main__":
    # os._exit: after a cluster was lost, closing the pool at interpreter exit can block for a long time (run 6: 12 minutes,
    # with the result already written). This is a test tool, there is nothing left to clean up.
    os._exit(main())
