# Future binlog support

The user deferred row-image variants, tagged GTIDs and XA while beta.6 DDL work
continues. These remain implementation gaps. The current FULL-row, ordinary-GTID
contract does not change. Do not advertise complete MySQL support while these
requirements remain open.

## MINIMAL and NOBLOB row images

Represent absent fields separately from SQL NULL. Build UPDATE and DELETE from
the fields present in each image and a valid row identity. Do not treat target
values as source evidence. Cover composite keys, key changes, keyless duplicates,
generated columns, excluded tables, and recovery records. Test live capture,
offline replay, rotation and saved-state restart on applicable profiles.

## Tagged GTIDs

Use one identity model across decoding, previous-GTID sets, resume/stop limits,
SQLite checkpoints, archive inventory, skip records and control commands.
Provide a durable-state migration design before changing stored identities.
Test mixed tagged/untagged history, duplicate suppression, restart and replay.
Do not reduce a tagged GTID to an ordinary SID/sequence pair.

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
