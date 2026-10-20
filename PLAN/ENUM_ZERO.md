# ENUM ordinal zero

Status: beta.6 implementation. This does not add other label encodings or remove
ordered-label checks. See [the support plan](COMPLETE_MYSQL_SUPPORT.md).

## Native behavior

An ENUM can contain ordinal zero when source SQL runs in non-strict mode. This
is the error value. It is not label one, even when label one is an empty string.
Native row replication copies the ordinal. A strict SQL INSERT of numeric zero
raises error 1265. The local MySQL 5.7.42 probe confirmed this distinction.

In the pinned 5.7 source, `Field_enum::store(longlong, bool)` in `sql/field.cc`
issues the warning for zero. `Field_enum::store_type` writes the packed ordinal.
The decoder already represents ENUM values as unsigned integers.

## Apply behavior

Only an INSERT or UPDATE whose after-image contains ENUM ordinal zero uses a
non-strict session mode. The statement remains an ordinary INSERT or UPDATE.
It does not use IGNORE, REPLACE, or upsert. Duplicate-key errors remain errors.
Other writes use the existing strict mode.

After the write, the applier reads all affected rows and compares their complete
values with the source after-images. This catches other conversions that could
occur while strict mode is off. The applier restores strict mode on both success
and failure. If restoration fails, it closes the connection and stops. It must
not skip a prior duplicate-key error and continue with the wrong session mode.

InnoDB uses an explicit transaction for these writes. The result check runs
before COMMIT, so a mismatch can roll back. MyISAM can retain a partial write.
Its failure record keeps the affected group pending for DBA review, as before.
A matching row does not prove that a later COMMIT response was received.

## State and tests

No SQLite schema or relay format change is needed. The existing schema and raw
relay event retain enough information to reconstruct ordinal zero. Recovery
continues to distinguish zero from an empty-string label's ordinal.

Unit tests cover mode restoration, restore failure, duplicate-error preservation,
ordinary strict writes, InnoDB rollback and relay/state reconstruction. Shared
`enumzero` cases cover live CREATE, bootstrap discovery, multi-row INSERT, NULL,
primary-key changes, UPDATE, DELETE and restart on all four profiles. Record
passing run IDs in [beta.6](beta.6.md) after the final checks.
