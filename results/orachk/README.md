# ORAchk on the primary cluster

[`r6_before-summary.txt`](r6_before-summary.txt): health score 91, 2 CRITICAL, 3 FAIL, 12 WARN, 128 PASS. The score is ORAchk's own, the counts are parsed from its HTML report. The
report stays on the node: it lists the host in detail and is regenerated at every run.

**What it covers:** OS, ASM and cluster checks on prm1 and prm2. Database checks did not run (the report shows no running instances and no MAA scorecard), so this says nothing about Data Guard or database settings; those
are covered by the broker's `validate` commands ([before](../maintenance/r6-broker-validate-before.txt)). It ran over the TFA socket with TFA started for the run: over SSH ORAchk crashes in its own code
(`NameError: BadHostKeyException`, paramiko cannot load `libffi.so.6`) when SSH to root is missing, and this lab does not add a root key for a tool. As `oracle` it fails with "TFA socket connection is not available".

| Status | Check | Decision | Reason or action |
|--------|-------|----------|------------------|
| FAIL | Integrity of key GI startup files | **Fixed** | OCR and OLR backups too old (no backups while the lab is off). Manual backups taken on both clusters |
| WARN | OCR backup in the same disk group as OCR | **Fixed** | `ocrconfig -backuploc +DATA` on both clusters: a lost `+OCR` no longer takes its backups with it |
| CRITICAL | Kernel and user core dumps | Accepted | `kdump` reserves memory a 7 GB VM cannot spare. `systemd-coredump` stays on to keep crash evidence; it once held 655 MB on prm3, cleaned by hand |
| CRITICAL | ORAchk scheduler | Accepted | The daemon needs TFA running, which is stopped to save memory. ORAchk runs by hand before major changes |
| FAIL | `rngd` service | Accepted | Package not installed and the VMs have no repository. `entropy_avail` is 256 on kernel 6.12 |
| FAIL | Cluster Health Monitor | Accepted | `ora.crf` disabled on purpose by `labctl.sh`, about 200 MB per node |
| WARN | Swap size, I/O scheduler, `ip_local_port_range` (65535 against 65500), bonding, jumbo frames, `compatible.rdbms`, packages, memory | Accepted | One-NIC lab VMs. `compatible.rdbms` cannot be lowered again once raised |
