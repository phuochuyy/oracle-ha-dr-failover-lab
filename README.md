# Oracle HA/DR Failover Lab

A self-built, two-region Oracle lab on Linux KVM. Each region is protected by Data Guard Fast-Start Failover, and GoldenGate keeps the two regions in sync in both directions.

The point of the project is the proof, not the install: the primary is switched over and powered off while both regions are writing, and afterwards every committed transaction is checked on both databases.

This is a home lab on one small host, not a production system.

## What is in it

- **Failover tests** under live write load, repeated after each major change.
- **GoldenGate that follows Data Guard** when the primary role moves to another site.
- **Lab automation** that starts only the machines a scenario needs.
- **Findings**: what broke during the tests, why, and how it was fixed, including my own mistakes.

## Where to look

- [Results of every run](docs/details.md)
- [Findings](docs/findings.md)
- [Architecture](docs/architecture.md)
- [Test report](docs/failover-test-report.md)
- [Test harness](tests/README.md)
- [Raw evidence](results/)
