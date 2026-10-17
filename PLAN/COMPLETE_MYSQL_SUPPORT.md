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

## Current beta.6 assessment

The support catalog is a partial inventory. It separates specific tool limits
from incomplete tests. `implemented` describes code, not release qualification.
`untested` means that the stated combinations are not fully tested; selected
cases can already pass. See [the status definitions](../docs/SUPPORT.md#support-status).
Do not use branch count or code coverage as a MySQL feature-support percentage.

### Confirmed tool limits

- Some opaque JSON subtypes and value ranges lack an exact SQL transport.
  Ordinary JSON works. See [JSON support](../docs/JSON_SUPPORT.md).
- Query events with nonzero source errors stop apply. A partially successful
  source DDL statement needs a separate result and recovery design.
- Table-name settings must match and must be 0 or 1. Mode 2 and cross-setting
  replication cannot be enabled. Native eligibility still needs review.
- MyISAM groups are limited to one row statement on one included table. Native
  GTID rules reject some broader forms. Do not assume that they reject all forms
  which this tool rejects.
- FULL row images and CRC32 are required. Transaction compression, tagged GTIDs
  and XA are not implemented. Row-image variants, tagged GTIDs and XA are
  deferred to [future event work](FUTURE_BINLOG_SUPPORT.md).

These are concrete restrictions, not a complete inventory of every MySQL form.
Value transport limits, including nonfinite floating-point values, remain in the
[support guide](../docs/SUPPORT.md).

### Native and target limits

A target cannot retain a feature absent from its version or engine. Examples
include 8.4-only index attributes on 5.7, foreign keys on MyISAM and native CTAS
restrictions under the tested GTID settings. Cross-version collation translation
uses explicit compatibility rules; it does not make all collations equivalent.
The [DDL native audit](DDL_NATIVE_AUDIT.md) also records the native FULLTEXT
replacement result. Do not report that native result as a tool defect.

Trigger, event, filter and explicit-engine policies are separate decisions.
The configured resource limits and DBA resolution of uncertain commits are also
policies. Keep their negative tests; do not count them as missing ordinary DDL.

### Implemented work that needs broader tests

The broad charset, expression, index, partition, conversion, stored-object,
row-identity and FK groups have selected passing tests. They still need boundary,
compound-operation and failure checks on the applicable profiles. A missing test
is not evidence that an entire feature family is unsupported.

Branch 69 implements [executable version comments](EXECUTABLE_COMMENTS.md).
The target evaluates the original comments; schema prediction follows its version.
Remaining lexical and failure combinations need qualification.

Branches 66 and 67 close the concrete
[column-name swap](SIMULTANEOUS_COLUMN_RENAMES.md) and
[partition-column rename](PARTITION_COLUMN_RENAMES.md) gaps.
The [DDL checklist](DDL_COMPLETION_CHECKLIST.md) retains implementation history.
Its old baseline labels are not the current unsupported-feature list.

Next work:

1. Run the combined release checks in GitHub. Keep evidence tied to exact builds.
2. Bind support assertions to evidence. Candidate case IDs alone do not qualify
   a catalog requirement. The support report retains `unverified` until this
   binding exists, even when a selected run has passed.
3. Audit remaining native-valid syntax and value combinations. Add a concrete
   tool-gap row only when code, a probe or a failed test identifies a restriction.
4. Keep deferred event formats and confirmed transport limits visible.

Keep all beta.6 branches local until the user approves publication. Branches 29
and 30 are experiment records; branches 32 and 33 replace their implementation.
Preserve their failure evidence.

## Original delivery plan

The numbered stages below retain the original goals and design order. They are
not a current missing-feature list. Use the assessment above, `support.json` and
the linked implementation records for current status.

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

- Branch 45 adds tables with an eligible nonnullable full unique key and no
  primary key. Branch 46 adds full-row matching for duplicate and keyless rows,
  including NULL, exact text, DECIMAL, signed zero and typed JSON. Save the lookup
  mode and retain each pending operation. Do not fold duplicate images into
  unique-key expectations. Complete unusual promoted-key metadata, base-column
  limits and the remaining value boundary matrix. See [keyless scope](KEYLESS_ROWS.md).
- Audit MyISAM transaction limits against native behavior before extending them.
  The existing native multistatement fixture expects error 1837. Keep that case
  as a negative test, not required positive support. Investigate other statement
  and table combinations separately. Extend only native-valid cases in this plan.
  Any deliberate extension beyond native GTID restrictions needs a separate
  design decision. Preserve operation order and record possible partial writes;
  MyISAM cannot provide rollback or atomic visibility.
- Self-references, cycles and per-event check settings are implemented in
  branch 47. Branch 48 adds supporting-index changes, column renames and internal
  database DROP. Extend the remaining DDL relationships.
  Branch 50 adds native nonunique, composite-prefix and extended parent keys.
  Branch 51 adds FK names, MATCH and native column compatibility. Branch 52
  adds cross-database DROP with surviving relationship records.
- Branch 49 adds disabled-check missing-parent DDL and parent recreation.
  Extend the remaining dependency-change forms.
  Keep native cascade behavior. Test explicit child changes and rollback.
  Keep the rejection of foreign keys across filter boundaries as a safety policy. Do not expand support by silently accepting broken relationships.
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
JSON changes. Continue with stage 3's table/index and ALTER work. Then continue
stage 4. The row-image, tagged-GTID and XA parts of stage 5 are future work.
Apply stage 6's acceptance checks to each increment and run
the full release checks at the end. Use one PR per testable feature family.

The remaining JSON transport, MyISAM transaction, and XA items need design
probes before schedule estimates. Keyless recovery now retains ordered operations;
its remaining boundary cases are listed in [the row-matching scope](KEYLESS_ROWS.md). Do not promise a completion date before those
probes establish what the ordinary MySQL client connection can preserve.
