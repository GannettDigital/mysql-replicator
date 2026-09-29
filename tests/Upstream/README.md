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
