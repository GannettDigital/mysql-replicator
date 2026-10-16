# Tagged GTID support

Status: implemented on 2026-10-16. Selected unit and live tests passed.
XA is outside this task.

## Conclusion

Tagged GTIDs do not require a new transaction execution model. They extend the
transaction identity and its text and binary formats. MySQL's transaction boundary
parser treats ordinary and tagged GTID events as the same boundary type.
The existing BEGIN, row-event, XID and standalone-DDL paths remain intact.
This is a moderate change across several components, not just a text-parser change.

MySQL defines a tagged GTID as `source_uuid:tag:transaction_id`. It groups intervals
by UUID and tag. A tag has 1 to 32 ASCII letters, digits or underscores, and cannot
start with a digit. Native code normalizes tags to lowercase. A GTID set can contain
several tags after one UUID. See the
[MySQL GTID format reference](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-concepts.html).

These identities must remain distinct, even when their sequence numbers match:

```text
aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:1
aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:blue:1
aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:green:1
```

## Automatic sequence assignment: native test

A direct test on MySQL 8.4.8 confirmed that automatic sequence numbers are separate
for each UUID/tag pair. The test used one session, one InnoDB table, and five
single-row INSERT transactions. It set only `GTID_NEXT=AUTOMATIC` or
`GTID_NEXT=AUTOMATIC:<tag>`. It did not assign a sequence number or a source UUID.

Before each INSERT, the test saved `@@GLOBAL.gtid_executed` in a session variable.
After each INSERT, `GTID_SUBTRACT()` returned the newly assigned GTID. All five
GTIDs had source UUID `8ae0df9a-c99d-11f1-b1d7-028b19e3f127`:

| Insert order | GTID_NEXT | Assigned GTID suffix |
| --- | --- | --- |
| 1 | AUTOMATIC | :8 |
| 2 | AUTOMATIC:blue | :blue:1 |
| 3 | AUTOMATIC:green | :green:1 |
| 4 | AUTOMATIC:blue | :blue:2 |
| 5 | AUTOMATIC | :9 |

Server initialization and table setup account for earlier untagged transactions.
Final executed set: `8ae0df9a-c99d-11f1-b1d7-028b19e3f127:1-9:blue:1-2:green:1`.
The blue transactions did not advance the green or untagged sequences.

The native implementation confirms this result. In `sql/rpl_gtid_state.cc`,
`specify_transaction_sidno()` maps the server UUID and session tag to an internal
identity number. `get_automatic_gno()` and `generate_automatic_gtid()` use that
number to select and update a separate entry in `next_free_gno_map`.

Automatic assignment is therefore distinct from a single counter for the server.
A privileged user can also assign a complete GTID through `GTID_NEXT`, but this
test did not use that mechanism. See the
[GTID_NEXT reference](https://dev.mysql.com/doc/refman/8.4/en/replication-options-gtids.html#sysvar_gtid_next).

## Audit before implementation

| Area | Behavior before this change | Required change |
| --- | --- | --- |
| Rust decoder | Rejects event type 42 and tagged Previous_gtids sets | Accept and validate both formats; return the tag through the codec interface |
| Rust dependency | The pinned mysql_common revision already parses both formats | Reuse it; retain bounds checks before allocations and test malformed input |
| SourceGTID | Holds UUID, sequence and flags | Add a tag and one canonical identity formatter/parser |
| GTIDSet | Groups intervals by UUID only | Group by UUID plus tag; update parse, format, include, contains, union and covers |
| Capture resume | Encodes only ordinary GTID sets for COM_BINLOG_DUMP_GTID | Encode the native tagged format when needed; keep the old format for ordinary sets |
| Archive | Reads only ordinary Previous_gtids; checks history with GTIDSet | Share tagged-set decoding and identity rules with live capture |
| SQLite | Stores singleton GTIDs and GTID sets in TEXT columns | Replace two-field parsing and UUID/sequence concatenation; preserve the full identity |
| Controls and reports | Use the same GTID types and saved strings | Test stopAfterGTIDs, configured baselines, skip, inspect and recovery reports with tags |

The pinned dependency is `rust_mysql_common` revision
`374c9d5c24f76a00b678d5b1d7103d6ceb4edb8c`. Its `gtid_event.rs` and
`previous_gtids_event.rs` contain tagged-format support. This review does not prove
that every malformed-input path in that dependency is safe. Our adapter must keep
its own size/count checks and retain the tag instead of discarding it.

## Saved state and target behavior

SQLite format 12 retains full GTID text in the existing columns. Ordinary GTID
strings do not change. Older binaries reject format 12. Back up stopped state
before an upgrade. The raw relay format does not change. A shared parsed identity
now supplies checkpoint, duplicate, skip and recovery operations.

The GTID-set bounds remain 64 identities and 4096 intervals per identity. Each
UUID/tag pair counts as one identity. The text limit remains 1 MiB.

The default `target.preserveSourceGTIDs: true` assigns each source identity to
its target transaction. A target without tagged-GTID support blocks tagged
transactions before application writes. Tags are never removed or renumbered.
Cloud SQL 8.4 also restricts tagged GTIDs. See
[GTID preservation and required privileges](../docs/GTID_PRESERVATION.md).

With `target.preserveSourceGTIDs: false`, SQLite retains the complete source
identity and the target uses its own GTID assignment. This permits tagged events
to be applied to 5.7 without a tagged target GTID. The source checkpoint remains
in SQLite in both cases. State format 12 pins this option; older state requires
explicit `false`.

## Implementation steps

1. Add the shared identity and tagged GTID-set model. Test canonical text, case
   normalization, interval operations, duplicate detection and configured limits.
2. Extend the Rust/Swift codec interface for event type 42. Add bounded tagged
   Previous_gtids parsing and native GTID-set encoding for source resume.
3. Update live capture, archive inspection, replay, state, skip and recovery
   readers. Add the saved-state version change and old-state tests.
4. Add shared integration cases with an 8.4 source and a 5.7 MyISAM target. Compare
   rows with the 8.4 native reference. Check source identities separately from the
   external target's own GTIDs.

## Test checklist

- Mix ordinary GTIDs and two tags under one UUID. Include equal sequence numbers.
- Compare text and binary GTID sets with MySQL. Include several tags under one
  UUID, upper/lowercase input, empty sets and interval boundaries.
- Decode real tagged DDL and DML events. Reject truncated events, invalid tags,
  excessive counts and unknown required serialization fields.
- Apply, stop and resume through tagged history. Test process restart, source
  disconnect, binlog rotation and duplicate suppression.
- Fetch and replay an archive with tagged Previous_gtids. Test baseline exclusion,
  archive history checks and an exact tagged stopAfterGTIDs limit.
- Test filtered groups, error skips, operator skip and recovery inspection. Each
  saved record must keep the full tagged identity.
- Reopen existing ordinary-GTID state with the new binary. Verify that ordinary
  5.7 sources still receive the old dump-request format.

## Local source references

Paths below are relative to the MySQL 8.4 checkout in `.upstream/mysql-server`:

- `libs/mysql/binlog/event/binlog_event.h`: `GTID_TAGGED_LOG_EVENT = 42`.
- `libs/mysql/binlog/event/trx_boundary_parser.cpp`, `get_event_boundary_type`:
  ordinary and tagged GTIDs use `EVENT_BOUNDARY_TYPE_GTID`.
- `libs/mysql/binlog/event/control_events.cpp`, `read_gtid_tagged_log_event`, and
  `control_events.h`, `define_fields`: tagged event serialization.
- `sql/rpl_gtid_set.cc`, `encode_nsids_format`, `encode` and `add_gtid_encoding`:
  tagged set header and interval encoding.
- `libs/mysql/gtid/tag.cpp`: validation, lowercase normalization and tag encoding.
- `sql/rpl_binlog_sender.cc`, `skip_event`: source exclusion uses UUID plus tag.
- `sql/rpl_replica.cc`: native code selects an older set format for older sources.

Repository entry points: `Sources/ReplicatorCodec/Control.swift`,
`Sources/ReplicatorCapture/Protocol.swift`, `BinlogArchive.swift`, `ArchiveReplay.swift`,
`Sources/ReplicatorApply/StateStore.swift`, `RecoveryStore.swift`,
`TargetContract.swift`, and `rust/src/lib.rs`.

## Test results on 2026-10-16

The selected `ddl-compat-tagged-gtids` case passed on
`mysql84-to-mysql57-myisam` with the default variant. It compared source, native
reference and external-target rows after tagged CREATE, INSERT, ALTER, UPDATE
and DELETE. It also checked rotation, process restart, saved full identities,
archive replay, a tagged `stopAfterGTIDs` limit and replay resume.

Artifact: `artifacts/lab/20261016T201908Z-63073569`.

Rust tests check event decoding, previous-GTID formats, truncation and size limits.
Swift tests check set operations, dump encoding, equal counters under different
tags, duplicate detection, checkpoint reopen and the format-10 state upgrade.
Tagged error skips, operator skip, recovery inspection and source reconnect still
need dedicated integration cases. Full release tests remain assigned to CI.
