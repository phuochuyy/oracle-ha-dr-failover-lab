#!/usr/bin/python3
"""Giữ distribution path Active-Active trỏ đúng sau Data Guard role transition.

Chạy trên node đang chạy deployment (CRS action script ở Region A, ogg-ha controller ở Region B):
  1. tìm địa chỉ đang sống của deployment đối tác, sửa target của path đi ra nếu sai;
  2. sửa target của path đối tác gửi về mình theo địa chỉ hiện tại của mình.
Cấu hình: /u01/app/oracle/ogg_ha/pathsync.conf (KEY=VALUE).
Dùng như CRS action script: start (bật + đồng bộ), check (đồng bộ; OFFLINE nếu chưa start), stop/clean.
Lỗi mạng/REST chỉ ghi log, không làm resource lỗi.
"""
import base64, json, os, socket, ssl, sys, time, urllib.request

CONF = "/u01/app/oracle/ogg_ha/pathsync.conf"
# Trạng thái resource cho CRS: check phải trả OFFLINE (≠0) sau stop, nếu không 'crsctl stop crs' thất bại.
STATE = "/run/ogg/pathsync.online"
LOG = "/u01/app/oracle/ogg_ha/pathsync.log"


def log(msg):
    with open(LOG, "a") as f:
        f.write(time.strftime("%F %T ") + msg + "\n")


def load_conf():
    c = {}
    for line in open(CONF):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            c[k.strip()] = v.strip().strip('"')
    return c


class Rest:
    def __init__(self, user, pw):
        self.auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
        self.ctx = ssl.create_default_context()

    def call(self, method, url, body=None, timeout=8):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", self.auth)
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=timeout, context=self.ctx) as r:
            return json.load(r)


def target_uri(addr, deploy, trail):
    return f"wss://{addr}:443/services/{deploy}/recvsrvr/v2/targets?trail={trail}"


def retarget(rest, path_url, desired, label):
    path = rest.call("GET", path_url)["response"]
    if path["target"]["uri"] == desired:
        if path.get("status") in ("killed", "stopped"):
            log(f"{label}: {path['status']} -> running")
            rest.call("PATCH", path_url, {"status": "running"})
        return
    log(f"{label}: {path['target']['uri']} -> {desired}")
    rest.call("PATCH", path_url, {"status": "stopped"})
    target = dict(path["target"], uri=desired)
    rest.call("PATCH", path_url, {"target": target})
    rest.call("PATCH", path_url, {"status": "running"})


def main():
    c = load_conf()
    rest = Rest(c["OGG_USER"], c["OGG_PASSWORD"])
    host = socket.gethostname().split(".")[0]
    self_addr = dict(x.split(":") for x in c["SELF_ADDR_MAP"].split())[host]

    live = None
    for addr in c["PEER_ADDRS"].split():
        try:
            items = rest.call("GET", f"https://{addr}/services/v2/deployments", timeout=5)["response"]["items"]
            if any(i.get("name") == c["PEER_DEPLOY"] for i in items):
                live = addr
                break
        except Exception:
            continue
    if not live:
        return

    try:
        retarget(rest, f"http://localhost:9102/services/v2/sources/{c['OUT_PATH']}",
                 target_uri(live, c["PEER_DEPLOY"], c["OUT_TRAIL"]), c["OUT_PATH"])
    except Exception as e:
        log(f"{c['OUT_PATH']}: {e}")
    try:
        retarget(rest, f"https://{live}/services/{c['PEER_DEPLOY']}/distsrvr/v2/sources/{c['IN_PATH']}",
                 target_uri(self_addr, c["SELF_DEPLOY"], c["IN_TRAIL"]), f"{c['IN_PATH']}@{live}")
    except Exception as e:
        log(f"{c['IN_PATH']}@{live}: {e}")


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "check"
    if action in ("stop", "clean"):
        if os.path.exists(STATE):
            os.remove(STATE)
        sys.exit(0)
    if action == "start":
        open(STATE, "w").close()
    elif not os.path.exists(STATE):
        sys.exit(1)          # check: OFFLINE
    try:
        main()
    except Exception as e:
        log(f"error: {e}")
    sys.exit(0)
