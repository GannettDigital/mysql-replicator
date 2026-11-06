# Primary keys and named constraints: shared workflow review

Status: both retained-table workflows are implemented locally after `dae01c2`.
Fourteen focused unit tests passed. Both cases passed on default SQL,
8.4 → 5.7 MyISAM. The original case definitions, catalog and matrix are unchanged.

## Decision and fixture

`ddl-compat-primary-key-row-matching` and `ddl-compat-constraints` now use retained
tables and final observations. Both IDs remain in `keys-rows-gtids`. They share
its containers and running applier. No fixture group, profile or CI job was added.

Use retained tables and final observations. A retained table repeats the original
SQL through a selected operation under a different table name. Later operations
cannot overwrite that table's rows or schema. Compare those states at the end.
This follows the earlier type/value and DDL conversions.

These cases have no explicit mid-case restart, offline replay, source-version
branch or target-engine SQL branch. Keep their generic checkpoint, completed-DDL
and saved-schema restart checks. Do not add a new recovery or replay workflow.
Keep prefix keys, keyless recovery and FK cases outside this slice.

Consult the MySQL manuals before naming the checks. Use PRIMARY KEY, UNIQUE
indexes, composite keys and constraint symbols. The PRIMARY KEY index name is
`PRIMARY`; a supplied constraint symbol does not become its index name. Do not
name a new feature section after a test-runner operation.

## Preserved behavior

Both case definitions still match successful CI run `40454033524`, commit
`efb3458`. Together they contain 23 source operations, 16 explicit predicates
and 15 named assertions. The old runner also compares full rows and schema
after every operation. Preserve those states, including operations without a
fixed predicate or assertion ID.

| Case | Source operations | DDL | Fixed predicates | Named assertions |
|---|---:|---:|---:|---:|
| Primary-key row matching | 9 | 2 | 7 | 9 |
| Named PRIMARY/UNIQUE constraints | 14 | 7 | 9 | 6 |

The row-matching case checks:

- `PRIMARY KEY(report_date,id)` with equal IDs on different dates.
- Separate changes to the date part and integer part of that key.
- DELETE by the full composite key and unchanged neighboring rows.
- A `VARCHAR(20)` primary key with `utf8mb4_unicode_ci`.
- Exact key bytes after a case-only UPDATE and case-insensitive DELETE.
- Empty tables and their key definitions immediately after CREATE.

The constraint case checks:

- PRIMARY and UNIQUE constraint symbols in CREATE and ALTER.
- Named, unnamed and explicitly named UNIQUE indexes, including name precedence.
- Removal of an index, replacement of indexes and replacement of the primary key.
- Nullable unique values, including two distinct rows with NULL values.
- Single-row UPDATE and DELETE, including the affected row before deletion.
- Multirow INSERT, UPDATE and DELETE on a separate integer-primary-key table.
  Its value column remains NOT NULL. Do not merge it with the nullable UNIQUE-key
  table to reduce the table count.

Keep the nine `composite-primary-key-*` and `text-primary-key-*` assertion IDs.
Keep the six `primary-key-single-row-*`, `primary-key-row-values-create` and
`primary-key-multirow-*` IDs. These also supply the migration checks for
`matrix-composite`, `matrix-textkey` and `matrix-values`. A parent pass alone
does not replace those assertions.

## Saved costs and coverage limits

Values below are case seconds / harness SQL client calls for default SQL.
They exclude the separate fixture setup phase. All eight executions passed.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 MyISAM | 5.7 → 5.7 InnoDB |
|---|---:|---:|---:|---:|
| Primary-key row matching | 19.04 / 156 | 22.75 / 155 | 22.07 / 155 | 22.20 / 155 |
| Named PRIMARY/UNIQUE constraints | 23.78 / 222 | 30.15 / 221 | 29.05 / 221 | 29.32 / 221 |

The forward pair used 378 client calls and 42.82 case seconds. There were
81 schema-comparison calls. These are harness costs, not target applier calls.

Coverage belongs to the complete saved keys-rows-gtids fixture. It does not
identify exclusive lines for either case. Neither case can be removed on the
basis of that coverage. Their key shapes and intermediate conditions differ.

Evidence: `artifacts/primary-key-constraint-review/review.json`. It records every
original SQL statement, fixed predicate and assertion ID. It includes all eight
saved results and a proposed retained-state map.

## Implementation requirements

1. Keep the reviewed source definitions and catalog IDs as the original inputs.
   Build an explicit execution plan from them. Reuse source phases and final
   observations. Keep the main replication code unchanged.
2. Retain each original table state. The initial conservative plan uses seven
   history tables for row matching and twelve for constraints. The four original
   tables hold their final states. This preserves all 23 operation states.
3. Map all 15 named assertions to their exact retained states. Run the same fixed
   predicates with only table names changed. Include CREATE metadata and empty-row
   checks. Keep the schema comparisons for unnamed operations too.
4. Keep the generic phase guard that rejects hidden per-statement assertions.
   The generated execution steps can omit an assertion ID only after the plan maps
   that ID to a required final assertion. Reject incomplete, duplicate or unknown
   mappings. Do not remove IDs from the original catalog definitions.
5. Rename both qualified table references and the unqualified `ALTER TABLE aux`
   reference after `USE ddlcompat`. Preserve SQL, key definitions, collations,
   NULL behavior, row bytes and predicates apart from those table names.
6. Send the generated source operations in batches and query observations at the
   end. Keep the existing shared containers and applier. Retain the generic
   per-case saved-state checks for the first conversion. Do not introduce a
   restart after each retained state or assertion.
7. Check expanded GTIDs and offsets against the execution plan. The proposed
   bodies contain 25 and 65 logged statements, including history operations.
   They contain 9 and 38 DDL operations, and affect 27 and 48 rows. Setup,
   cleanup and restart probes are outside these totals. Confirm these counts
   with unit tests before the integration run.

The conservative retained-table plan adds 67 source statements. This is a small local
workload. It removes repeated network waits and full-schema reads. Do not remove
a retained state to reduce that count without showing which other assertion
checks its exact rows and metadata.

## Local verification scope

Add focused unit checks for SQL preservation, table mappings and all 15 assertion
mappings. Require every original operation state and predicate. Reject missing
states, duplicate names and duplicate assertion IDs. Test the unqualified ALTER
reference. Confirm expanded transaction, DDL and affected-row totals.

Run the affected workflow, phase-guard and catalog/migration unit tests. Build
once. Run both changed cases together on default SQL, 8.4 → 5.7 MyISAM, with
coverage. Require all named assertions, final rows/schema, completed intents,
checkpoints and the saved-schema restart. Inspect a failure's support bundle
before a rerun.

Do not rerun the other three profiles locally. These source operations have no
profile-specific branch. Add a focused profile run only if the implementation
introduces such a branch. Compare the generated catalog and full matrix without
running them. Leave the full group, other profiles, variants and CI timing to
GitHub Actions. Do not run syntax tests for this harness change.

## Implementation and focused results

`KeyConstraintWorkflows.swift` builds the execution steps from the unchanged
source definitions. The normal runner uses those generated steps for these two
IDs only. Catalog and native-only fixtures still use the original definitions.

Each case sends its original operations in one phase. A second phase repeats
the required prefixes on retained tables. Final observations check every original
state. They keep all 16 fixed predicates. The three named CREATE assertions also
check empty rows, column types, nullability, collations and primary-key parts.
The remaining assertions check the original index names or exact row values.
One full schema/row comparison per case checks all its retained tables against
the source and native replica.

The plan requires an exact mapping for every original named assertion. It rejects
missing states, duplicate table/assertion names and unknown named mappings. It
also rejects unreviewed transaction/restart or engine-specific SQL changes.
The generic phase guard remains unchanged. The two original case definitions
and all profile/variant selections remain unchanged.

Both cases keep the existing per-case saved-state restart. The outer fixture
also keeps its final restart and following write. No restart occurs between
individual retained states or assertions.

| Default SQL, 8.4 → 5.7 MyISAM | Row matching | Named constraints |
|---|---:|---:|
| Case seconds | 11.35 | 12.89 |
| Harness SQL client calls | 34 | 34 |
| Passing assertions | 13 | 18 |
| Original named assertions retained | 9 | 6 |
| Retained operation states | 9 | 14 |
| Body GTIDs | 25 | 65 |
| Body DDL operations | 9 | 38 |
| Affected rows, including histories | 27 | 48 |

The pair used 68 harness client calls. The saved CI pair used 378. Local case
time was 24.24 seconds. The saved CI time was 42.82 seconds on different hardware;
this is not a controlled speed comparison. These are harness costs, not target
applier statement counts.

All 31 assertions passed, including the 15 original named assertions. The saved
state audit checked every body GTID and its file/offset. All 90 groups were
APPLIED. The checkpoints had no unfinished row or DDL intents. Every retained
table had exactly one current saved schema.

The completed run used one container setup and six source phases. Fixture setup
took 14.88 seconds, including 12.10 seconds for container startup. Its four applier
invocations include the existing case and outer restart checks. They collected
8,083/20,880 runtime lines. This is coverage for the two selected cases and their
fixture checks, not the complete keys-rows-gtids group.

All 14 focused unit tests passed: KeyConstraintWorkflowTests,
DDLExecutionPhaseTests, the three affected LabProfileTests, and SupportCatalogTests.
The generated catalog and matrix matched exactly, apart from the build-input
digest. The plan remains 183 jobs, 1,545 obligations and 182 coverage collections.
The other profiles, variants and full group were not run locally.

The first image build stalled in SwiftPM before compilation and before fixture
setup. It had exited Git child processes that SwiftPM had not collected. The
build did not respond to SIGTERM and was stopped with SIGKILL. The retry built
normally. No integration case was repeated. The original log is retained as
`artifacts/primary-key-constraint-review/build-stalled.log`.

Passed lab result: `artifacts/lab/20261106T213452Z-a1cea42e/result.json`.
Other evidence is in `artifacts/primary-key-constraint-review/`:
`workflow-results.json`, `inventory-results.json`, `unit.log` and `integration.log`.

The primary-key and constraint workflows are committed as `c268dd7`. The
[conflict workflow results](BETA7_KEY_CONFLICT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
record all 11 original assertions and both unchanged no-op boundaries passing.
Fifteen focused unit tests passed. The REPLACE group still has three row mutations.

Next: review INSERT SELECT, joined UPDATE/DELETE and LOAD DATA.
