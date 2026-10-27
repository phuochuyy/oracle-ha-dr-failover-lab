#!/usr/bin/python3
"""verify.py <wl_A.log> <wl_B.log> <rows_siteA.txt> <rows_siteB.txt>
rows_*.txt: 'SITE SEQ' mỗi dòng, lấy từ DB của từng site."""
import sys
def logs(p):
    ok, err = set(), set()
    for l in open(p):
        f = l.split()
        if len(f) >= 3: (ok if f[2] == "OK" else err).add(int(f[1]))
    return ok, err
def rows(p):
    s = set()
    for l in open(p):
        f = l.split()
        if len(f) == 2: s.add((f[0], int(f[1])))
    return s
okA, errA = logs(sys.argv[1]); okB, errB = logs(sys.argv[2])
dbA, dbB = rows(sys.argv[3]), rows(sys.argv[4])
fail = False
for name, db in (("DB site A", dbA), ("DB site B", dbB)):
    for site, ok, err in (("A", okA, errA), ("B", okB, errB)):
        have = {q for s, q in db if s == site}
        miss = sorted(ok - have)
        extra = sorted(have - ok)          # chỉ hợp lệ nếu thuộc nhóm ERR (commit nhưng client không nhận được kết quả)
        bad_extra = [q for q in extra if q not in err]
        print(f"{name}: rows from {site}: {len(have):5d} | committed OK: {len(ok):5d} | missing: {len(miss)} {miss[:10]} | in-doubt present: {len(extra)-len(bad_extra)} | unexpected: {bad_extra[:10]}")
        fail |= bool(miss) or bool(bad_extra)
diff = sorted(dbA ^ dbB)
print(f"Site A vs Site B difference: {len(diff)} {diff[:10]}")
fail |= bool(diff)
print(f"ERR (client-side failed attempts): A={len(errA)} B={len(errB)}")
print("RESULT:", "FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
