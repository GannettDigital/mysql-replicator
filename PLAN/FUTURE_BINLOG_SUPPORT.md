# Future binlog support

Row-image variants and XA remain implementation gaps. FULL row images are
required. Tagged GTIDs are now implemented; see the test scope below. Do not
advertise complete MySQL support while the remaining requirements are open.

## MINIMAL and NOBLOB row images

Represent absent fields separately from SQL NULL. Build UPDATE and DELETE from
the fields present in each image and a valid row identity. Do not treat target
values as source evidence. Cover composite keys, key changes, keyless duplicates,
generated columns, excluded tables, and recovery records. Test live capture,
offline replay, rotation and saved-state restart on applicable profiles.

## Tagged GTIDs

[Tagged GTID support](TAGGED_GTIDS.md) keeps UUID, tag and sequence together in
capture, checkpoints, duplicate checks and replay. The default forward-profile
case passed with restart, rotation and a tagged replay stop limit. Dedicated
tagged skip, recovery and source-reconnect integration cases remain to be added.
XA remains a separate task.

## XA

Design prepare, commit and rollback as separate durable phases. Preserve prepared
transactions across process/source/target restarts and archive boundaries.
Define how an unresolved prepare affects stop limits and archive completion.
Use InnoDB for positive atomicity tests. MyISAM cannot provide XA guarantees.
Test failures around target commit and SQLite completion. Keep uncertainty
explicit when the two stores cannot establish one atomic outcome.

## Other event work still open

Transaction-payload compression and checksum modes other than CRC32 remain open.
They are not part of the current DDL changes. Compression needs bounded expansion
and corrupt-input tests. Checksum handling needs native NONE/CRC32 evidence and
live/replay parity. Unknown state-changing events must stop with a useful error.
