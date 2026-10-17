# Plan for complete MySQL replication support

Status: implementation started on the [beta.6 branches](beta.6.md).
This plan does not expand the current support contract.
See [current support and limits](../docs/SUPPORT.md) for implemented behavior.

## Goal and scope

Support all source row changes and application schema operations that the target
can represent on the four current profiles:

- MySQL 8.4 InnoDB → MySQL 5.7 MyISAM.
- MySQL 5.7 InnoDB → MySQL 8.4 InnoDB.
- MySQL 5.7 InnoDB → MySQL 5.7 MyISAM.
- MySQL 5.7 InnoDB → MySQL 5.7 InnoDB.

Use MySQL 5.7's data types and application schema features as the common target
feature boundary. Test source-version syntax and event differences separately.
A target-version limitation is not an implementation gap. For example, a 5.7
target cannot implement an 8.4-only column feature merely because we can decode
its event. Do not silently remove such a feature from DDL.

"Complete" must mean complete against a named catalog and pinned server versions.
It must not mean that every statement accepted by either MySQL version works on
all profiles. An unresolved implementation gap keeps its catalog item incomplete.
Record inherent version/engine limits separately, with native evidence and a
clear error. Do not count an arbitrary refusal as positive feature coverage.
The [native restrictions](../docs/SUPPORT.md#native-restrictions-and-tool-limits)
are part of this boundary. GTID restrictions apply even when capture starts from
a binlog file position. Positioning is not a way to enable non-GTID workloads.

Initial copies, server upgrades, account/plugin administration, replication
channel administration, and independent target writers remain outside the app's
scope. SELECT workloads and stored routine calls are not reconstructed from row
binlogs. Their recorded row effects are in scope. Automatic repair of uncertain
writes and new target engines are separate projects.

## Beta.6 assessment after the syntax extraction

The original plan in the beta.5 worktree remains the scope baseline. This copy
tracks beta.6 work. The support audit has 51 requirements. Most are broad groups,
not individual assertions. None is release-qualified yet. Do not use the branch
count or unit line coverage as a completeness measure.

| Area | Implemented work | Work still needed |
| --- | --- | --- |
| Values and names | Charset registry and byte transport, numeric defaults and attributes, ENUM zero and labels, native identifier comparison, non-UTF-8 query decoding, table-name case settings, JSON YEAR translation. | Complete the boundary, replay and failure matrix. Keep binary values inside JSON as a documented transport gap. |
| Table DDL | FULLTEXT subset, JSON generated indexes, table options, selected conversions, multi-table DROP and RENAME, subpartition metadata/lifecycle operations, KEY algorithms, partition maintenance, evaluated bounds and unchecked exchange. CTAS source and target restrictions are classified. | The selected charset, expression and geometry-prefix cases pass. Complete remaining index and partition operations, ALTER forms, CHECK qualification and stored-object behavior. FULLTEXT replacement after deletes still needs its native document-ID investigation. |
| Parser | Independent lexer and typed expression target, isolated unit coverage and Docker build stage. | Move additional grammar into typed syntax nodes. Expand expressions with native metadata comparison tests. Do not import the unfinished string-producing parser as a second grammar. |
| Row identity and relationships | Primary-key DML, selected InnoDB FKs and recovery records. | Unique-key fallback, duplicate/keyless matching, FK cycles and source foreign_key_checks behavior. Define durable recovery records before changing row identity. |
| Binlog events | Existing FULL row-image and ordinary GTID paths. | MINIMAL/NOBLOB images, compression, tagged GTIDs, XA and checksum modes. Each requires live, replay and restart checks. |
| Qualification | Shared four-profile harness, native comparisons and support bundles. | Bind catalog assertions to exact builds. Run full release checks and representative performance checks after the remaining implementation work. |

Current execution order:

1. Completed: confirm the combined charset ALTER, generated-expression and
   geometry-prefix increments with fixed inputs on all applicable profiles.
   Run `20261015T073916Z-20bde8e4` passed 21 applicable cases.
2. Move the remaining DDL statement grammar into typed syntax nodes. Complete
   the remaining ALTER, index and partition forms, including subpartitions.
   FORCE and ENABLE/DISABLE KEYS now pass on all four profiles. See
   [maintenance checks](TABLE_MAINTENANCE.md). Branch 37 adds subpartition
   metadata and selected lifecycle operations, with passing tests on all four
   profiles. Branch 38 adds KEY algorithm metadata and partition maintenance.
   Branch 39 adds native bound evaluation and EXCHANGE WITHOUT VALIDATION.
   Branch 40 adds exact binary/charset COLUMNS bounds and native conversion
   checks. It records the tested native restrictions on misplaced-row DML.
   See [partition work](PARTITION_SUPPORT.md)
   for implementation, tests and the remaining forms.
3. Classify CHECK and CTAS by source version and target engine. The native
   [5.7 to 8.0 CHECK rule](CHECK_CONSTRAINTS.md) is implemented in branch 36;
   selected live and offline checks passed on all three 5.7-source profiles.
   Branch 41 records permanent CTAS native limits and adds temporary CTAS live,
   restart and replay cases. See [CTAS contract](CREATE_TABLE_SELECT.md).
   Next, audit views, routines, definers and remaining temporary cleanup forms.
   Branch 42 adds routine ALTER, parenthesized views and multi-view DROP.
   See [stored-object scope](STORED_OBJECT_SUPPORT.md) for the native rules,
   verification. Branch 43 adds conditional routine CREATE translation.
   Branch 44 adds view renaming and mixed table/view rename lists.
4. Add unique-key and keyless row identity. Define durable recovery records
   before changing the DML selection path. Then extend FK relationships and
   source foreign_key_checks behavior.
5. Add row-image and event variants. XA and tagged GTIDs need durable-state and
   archive designs, not decoder changes alone.
6. Run qualification and publish native limits separately from tool gaps.

The catalog still marks eight tool-gap groups as missing:
unique-key identity, keyless identity, disabled FK checks, MINIMAL/NOBLOB images,
transaction compression, tagged GTIDs, XA and checksum modes other than CRC32.
The remaining `subset` entries also need work. Those include expression and
partition forms, FK relationships, replay/failure coverage and value boundaries.
This list is not a claim that the partial inventory contains every missing form.

Other entries marked `missing` describe native restrictions, a target
limit, or the existing scheduled-event rejection policy. Do not report these as
missing replication features. Their evidence or catalog status needs review.
In particular, event rejection already exists in `DDLPolicy` and the shared
`ddl-compat-reject-event` case. Qualification remains separate from implementation.

Branches 29 and 30 remain experiment records. Branches 32 and 33 replace their
implementation work. Keep their saved failure bundles. Keep all beta.6 branches
local until the user approves publication of the complete stack.

## 1. Establish the support catalog

Extend the existing DDL catalog and shared lab inventory instead of creating a
second test runner. Add explicit DML/type and event-format requirements where
only case names exist today. Each requirement needs:

- Source version, target version, engine, and applicable capture variants.
- Native source behavior and native same-version replica behavior.
- Classification: native restriction, target limit, tool gap, safety policy, or untested.
- Expected external behavior: apply, explicit policy action, or target limitation.
- Implementation status, test IDs, assertion IDs, and evidence for the exact commit.
- Remaining constraints, including configuration and privilege requirements.

Use the local 5.7 and 8.4 upstream trees to find relevant tests and implementation
rules. Audit explicit refusals in the decoder, source contracts, DML type parser,
DDL parser, schema discovery, and recovery code. Distinguish source rejection,
target rejection, an applier limitation, and an untested path.

Check native eligibility before adding implementation work. Record the exact
version, engine, GTID settings, SQL mode, and filters. Exclude native-rejected
cases from the positive-support denominator. Keep them in the negative-test
catalog. Report safety policies separately; do not present them as native limits.
For example, 5.7 source CREATE TABLE SELECT with GTID consistency enabled needs a
source-rejection test, not an applier implementation. Explicit incompatible
engines do not require engine rewriting. Native ROW filtering can split a
transaction, so a filter crossing alone is not proof of native rejection.

First review the beta.5 full-CI results. Local selected JSON and spatial runs do
not qualify every new BIT, floating-point, event, or DDL combination. Do not rerun
passing broad suites merely to populate the catalog; import existing evidence
when its code, fixture, and assertion identities match.

Done: every known limitation in docs/SUPPORT.md and the implementation has a
catalog entry, an owner stage below, and a stated success criterion.

## 2. Complete stored values, encodings, and identifiers

Prioritize application schemas that currently fail discovery or CREATE:

1. Add a version-aware charset/collation registry. Start with utf8mb3, latin1,
   ascii, binary, and the other target-supported utf8mb4 collations. Then cover
   all remaining 5.7 character sets. Keep column bytes and encoding metadata
   separate. Do not decode arbitrary strings as UTF-8 or infer encodings from data.
2. Remove artificial string-width restrictions where native limits permit it.
   Test byte versus character lengths, multibyte boundaries, padding, trailing
   spaces, embedded NUL, and SQL mode effects. Keep configured resource limits.
3. Add fixed-scale FLOAT/DOUBLE and applicable numeric attributes. Check actual
   stored bits, overflow, underflow, rounding, defaults, and metadata normalization.
4. Handle native ENUM ordinal zero and metadata-ambiguous labels where MySQL
   permits them. Investigate the native path and source schema provenance before
   replacing a validation rule. Preserve label order and distinguish missing
   metadata from conflicting metadata.
5. Permit native-valid identifiers with correct quoting and byte handling.
   Test non-ASCII names, reserved words, embedded backticks, maximum lengths, and
   lower_case_table_names behavior. Do not silently rename objects.
6. Investigate each remaining JSON opaque subtype and value-range gap. Prove an
   exact SQL construction path with type and value checks on both target versions.
   If the client protocol cannot represent a native value, record that result and
   review a separate transport design. Do not substitute strings or approximate
   numbers. A target extension would change the deployment contract and needs its
   own design decision. The explicit 5.7 to 8.4 YEAR-to-integer rule is an
   approved exception to exact type preservation. It is disabled by default.
   See [JSON_YEAR_COMPATIBILITY.md](JSON_YEAR_COMPATIBILITY.md).

Place type codecs and version rules behind small interfaces. Keep transaction
ordering, checkpointing, and error handling generic. Avoid a general plugin
framework until a concrete second implementation needs it.

Done: each supported type/encoding passes boundary values, NULL, INSERT, UPDATE,
DELETE, applicable keys/defaults, bootstrap discovery, live capture, replay, and
saved-state restart. Unrepresentable cross-version values have specific errors.

## 3. Complete table and DDL behavior

Expand the parser and schema model by feature family. Do not add a raw-SQL fallback
that bypasses filters, schema tracking, or recovery records.

1. Add ordinary table options, FULLTEXT indexes, supported spatial BTREE prefix
   indexes, and the remaining native-valid index forms at the 5.7 boundary.
2. Add cross-family column conversions and remaining ALTER operations. Let the
   target execute the source SQL under compatible logged session settings.
   Increment 27 adds parsed table options and native cross-family conversions.
   Its selected cases include exact defaults, row changes and restart. Increment 32 adds table-default changes, native charset conversion and equivalent legacy DEFAULT syntax.
   Other ALTER forms and the full conversion matrix remain open.
   Verify resulting metadata and subsequent row effects. Do not predict a lossy
   conversion as exact when native behavior depends on SQL mode or table data.
3. Complete generated-expression coverage and partition operations, including
   subpartitions. Test evaluation changes across versions and retain source-value
   comparison where it is needed.
   Current JSON work adds extraction and CAST expressions, indexed generated
   columns, and 8.4 target discovery of functional indexes and JSON expression
   defaults. It does not complete the expression grammar or partition work.
   See [JSON support](../docs/JSON_SUPPORT.md#json-indexes-and-defaults).
4. Add ordered multi-table DROP and cross-schema RENAME. Include filter boundaries,
   name case rules, FK dependencies, partial failure, and saved schema retirement.
   Increment 28 implements DROP lists and cross-schema RENAME through the
   existing multi-table DDL journal. Shared cases cover moves, swaps, FK
   relationships, following DML and restart. Unit checks cover filter boundaries
   and atomic local checkpoint failure. A target DDL failure remains pending;
   automatic DDL repair is not implemented.
5. Classify CREATE TABLE SELECT by source version and target engine first.
   MySQL 5.7 source rejection under GTID consistency is outside positive support.
   Branch 41 classifies 8.4 atomic CTAS as a target limit for the forward profile.
   The generated START TRANSACTION clause fails on native MyISAM and on 5.7.
   Shared tests cover temporary CTAS permanent-row effects, restart and replay.
   See [native CTAS contract](CREATE_TABLE_SELECT.md). Never execute the SELECT
   and then also apply its generated row events.
6. Audit views, routine DDL, definers, conditional DDL, and temporary-table event
   behavior. Source temporary objects and their permanent-table effects are
   different requirements. Preserve row-mode cleanup semantics.
7. Test CHECK and other syntax whose enforcement differs by server version.
   Require an explicit compatibility decision where equivalent behavior is not
   available. Successful parsing alone does not establish correct behavior.

Done: native-reference tests cover source acceptance/rejection, event sequence,
target schema/data, following DML, filters, clean restart, and failure state for
each DDL family. Every source statement is applied at most once in the normal
run; uncertain DDL is recorded for DBA review rather than retried blindly.

## 4. Complete row identity, transactions, and relationships

- Add tables without a primary key. First use a suitable unique key; then design
  the full-row matching path for keyless tables and duplicate rows. Prove correct
  row multiplicity, NULL matching, comparison semantics, and DELETE/UPDATE limits.
  Recovery must identify candidate rows without claiming that a duplicate row
  proves which source change completed.
- Audit MyISAM transaction limits against native behavior before extending them.
  The existing native multistatement fixture expects error 1837. Keep that case
  as a negative test, not required positive support. Investigate other statement
  and table combinations separately. Extend only native-valid cases in this plan.
  Any deliberate extension beyond native GTID restrictions needs a separate
  design decision. Preserve operation order and record possible partial writes;
  MyISAM cannot provide rollback or atomic visibility.
- Extend InnoDB FK handling to native-valid self-references, cycles, supporting
  index changes, and remaining DDL relationships. Treat nonunique/partial parent
  keys as version-specific: confirm that the selected target permits them.
- Design handling for source foreign_key_checks changes. Account for the target's
  own cascade actions and the row events the source records. Avoid applying a
  cascade twice. Test explicit child changes, cascades, and rollback. Keep the
  rejection of foreign keys across filter boundaries as an explicit safety
  policy. Do not expand support by silently accepting broken relationships.
- Keep source trigger row effects in scope. Installing active target triggers is
  a separate problem because external SQL can fire them again. Do not change the
  current skip/reject policy until a tested design prevents duplicate effects.
  Scheduled target events likewise must not create a second writer.

Done: compare operation sequences and final rows with the native reference. Inject
failures before submission, after partial execution, around commit, and before
SQLite completion. Recovery output must identify the uncertain group and possible
relationship effects. Exact recovery is not a condition for MyISAM support, but
accurate uncertainty reporting is.

## 5. Complete source event and row-image variants

Add one event family at a time:

- MINIMAL and NOBLOB row images. Represent an absent column separately from NULL.
  Use source keys and saved schema for SQL construction. A target read can supply
  values for validation only when that inference is safe; it is not source evidence.
- Transaction payload compression, with limits on decompressed bytes and nesting.
- Tagged GTIDs, including previous-GTID sets, resume, stop limits, SQLite state,
  archive inventory, skip records, and control commands.
- XA prepare/commit/rollback, including prepared state across disconnects and
  archive boundaries. Preserve the target engine's possible semantics; a MyISAM
  profile cannot acquire InnoDB's XA guarantees.
- Remaining checksum modes and ignorable event classes, after native review.
  Unknown state-changing events must still stop with useful diagnostics.

Keep binlog_row_metadata MINIMAL separate from binlog_row_image MINIMAL: the
former is already tested on the forward profile; the latter is new work.

Done: live and offline replay agree on rows, GTIDs, and stop boundaries across
rotation, source restart, target restart, and truncated/corrupt input. Decoder
limits prevent unbounded allocation and decompression.

## 6. Qualify and publish the declared scope

Run the full catalog on release binaries for all four profiles and applicable
variants. Compare schemas, exact stored values, operation sequences/binlog effects,
checkpoint progression, and errors. A final-state-only comparison is insufficient.
For cross-version cases, use a same-version native replica as the source behavior
reference and independent target assertions for documented version differences.

Keep unit tests for framing, metadata, parser behavior, and fault boundaries.
Use real MySQL fixtures for storage, SQL modes, DDL, collation, and constraint
semantics. Reuse shared profile cases. Add version-specific expected outcomes
only when native evidence supports them. Code coverage helps find unexercised
paths; it does not replace the feature catalog.

Select focused cases during implementation. Run broad regression checks in
GitHub. Recheck representative performance workloads after stages that add
per-row conversions, target reads, SQL statements, or transaction barriers.

Publish a support report with the release: passed requirements, inherent target
limits, unresolved implementation gaps, test commit, and artifact identity.
Claim complete support only for the declared catalog when it has no unresolved
implementation gaps. Do not change the scope merely to make the percentage 100%.

## Recommended delivery order

Deliver stage 1 first, then stage 2 in separate charset, scalar/identifier, and
JSON changes. Continue with stage 3's table/index and ALTER work. Then implement
stage 4 and stage 5. Apply stage 6's acceptance checks to each increment and run
the full release checks at the end. Use one PR per testable feature family.

The JSON transport, keyless recovery, MyISAM transaction, and XA items need design
probes before schedule estimates. Do not promise a completion date before those
probes establish what the ordinary MySQL client connection can preserve.
