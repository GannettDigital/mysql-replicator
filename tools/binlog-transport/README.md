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
