# Upstream codec qualification

Run make upstream-tests, or swift run replicator-lab upstream-tests.
The runner fetches and verifies mysql_common commit
374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c, checks tracked source changes,
installs the committed research lockfile, and explicitly runs the binlog suite
with test,binlog,flate2/rust_backend. All 26 tests must pass.

Cargo.lock was imported from the approved codec research in the original
maxwell-mysql-consumer workspace. Its SHA-256 is
695cb4cd8aaaff28ae45e33db942762b80eeeca9867e887a2c1c08dd7b4333e8.
It is a test lockfile, separate from the production adapter's rust/Cargo.lock.
The production dependency never enables the upstream test feature.

Artifacts include the toolchain, test log, fixture paths/commit/URLs/checksums
and a result document. Upstream tests use a MySQL C++ decimal reference.
Some platforms require downloading/building its MySQL 8.0.35 sources; this is
not part of the production binary. The Linux release build is not qualified
by a passing host test run.

The generated fixture catalog establishes source identity, not complete Swift
coverage or redistribution clearance for every historical binary file. Review
each fixture's provenance before importing it into the committed Swift corpus.
The repository code is MIT/Apache-2.0; preserve upstream notices when porting
test vectors. Fixture bytes remain in the ignored upstream checkout.

## MySQL 5.7 target reference

The target compatibility boundary is MySQL 5.7.44. The existing MySQL 8.4
reference remains the source-side reference. The additional checkout is ignored
by Git, with its tag, immutable revision and selected file hashes recorded in
[mysql57.json](mysql57.json) and its repository registered in the DDL catalog.

```sh
git clone --depth 1 --branch mysql-5.7.44 --single-branch https://github.com/mysql/mysql-server.git .upstream/mysql-server-5.7
git -C .upstream/mysql-server-5.7 rev-parse HEAD
# Expected: f7680e98b6bbe3500399fbad465d08a6b75d7a5c
```

The MySQL source retains its own license and is not linked into the replicator.
The DML matrix contains original SQL fixtures informed by these references;
we do not claim to run or pass MySQL's complete MTR suites. Support requires
end-to-end qualification, not merely the presence of a type in 5.7. Features
unavailable on the target fail explicitly rather than undergoing a lossy mapping.

Run the prepared-table compatibility matrix with:

```sh
make dml-suite ARGS="--slice matrix"
```

This tests both GTID/FULL-metadata and file-position/MINIMAL-metadata profiles.
Row images remain FULL in both. Evidence includes SQL, independent expectations,
exact source/native/target row bytes after each phase, and saved checkpoints.
