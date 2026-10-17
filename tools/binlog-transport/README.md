# BINLOG transport probe

This is a beta.7 research tool. It tests MySQL's BINLOG statement on new disposable
servers. It does not run mysql-replicator, test its recovery, or measure native
replication performance. See [the implementation plan](../../PLAN/BINLOG_TRANSPORT.md).

Use the local images from the existing lab. Build the 5.7 fixture image if needed:

```sh
docker build --platform linux/amd64 -t mysql-replicator-fixture:5.7.42-setpriv docker/mysql57
python3 tools/binlog-transport/probe.py --profile all --output artifacts/binlog-transport/run-1
```

The pinned 8.4 image must also be available locally. The probe does not pull
images. Use `--help` for image overrides and individual profile IDs. The output
directory must be new. Run profiles one at a time to limit container use.

The tool creates two containers per profile, with no published ports or external
network. The MySQL client connects over TCP to port 3306 inside each container.
It removes only the containers and volumes it creates, including after failure.
It never connects to an existing demo or a supplied database address.

Each profile saves the source binlog, generated SQL, server logs, target binlogs,
and a result file. Values and passwords are synthetic. The source and target FDE
experiments are separate; a pass with one does not make the other a supported
conversion rule. A nonzero process exit means at least one profile had no passing
path or setup failed. Always inspect the individual experiment results.

The row comparator supports only this fixture's three-column FULL row images.
It compares exact field bytes, including binary JSON. Unused bitmap padding is
ignored. SQL JSON rendering can differ between versions even when bytes match;
the report records that rendering separately.

Run the probe's parser and comparison unit tests:

```sh
python3 -m unittest discover -s tools/binlog-transport -p test_probe.py
```

Production support must use the shared lab profile and case selection system.
This script is a native behavior experiment, not a second correctness suite.

## Request boundaries and failures

Reuse the saved source events to test a new target for each profile:

```sh
python3 tools/binlog-transport/behavior_probe.py --profile all \
  --source-directory artifacts/binlog-transport/run-1 \
  --output artifacts/binlog-transport/boundaries-1
```

Use repeated `--case NAME` options to run selected cases. For example, use
`--case automatic --case packet-limit` to check only those cases. The restricted
account check runs with each selection. Input files must come from `probe.py`.

This probe checks MySQL's behavior, including known failures. A passing `split`
check means that MySQL reproduced the known failure: separate map and row
requests apply no rows without an SQL error. A passing MyISAM `multi-statement`
check means that the first statement applied and the next failed with error 1837.
Read `expectedRows`, `expectedErrorCodes`, and `sourceGTIDPresent` in the report.
These cases must not become accepted applier execution paths.

The probe uses `mysql --force` to test COMMIT and ROLLBACK after an error. The
production executor must stop at the error. MyISAM can keep both partial row
writes and the source GTID. Do not infer complete application from that GTID.

The output directory must be new. Keep failed results and use a new directory
for a corrected run. Some cases intentionally produce no target rows, so their
pass condition checks the exact error or native behavior, not only the client
exit code. Packet-limit and missing-format checks require zero target rows.
