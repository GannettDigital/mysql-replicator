# Table, column and index workflow review: completion and next area

## Decision

The current `table-column-index-changes` group has no remaining ordinary case
to convert to the shared batch/observation approach. All 20 compatibility cases
use `finalObservations`. `ddl-modify-columns` uses the separate shared MODIFY
workflow from the pilot. Keep its normalized-binlog and intermediate row checks.
Do not force it into the generic final-observation helper.

This completes the local implementation work for this area in Slices 1–2 of
[BETA7_TEST_SUITE_CONSOLIDATION.md](BETA7_TEST_SUITE_CONSOLIDATION.md#current-execution-plan-after-the-modify-pilot).
It does not complete full-suite validation. No new full-group timing or coverage
measurement exists yet. This review added documentation only; no build or test
ran for the review.

Slice 3 has started. The two ordinary partition workflows now pass focused
local checks; see the results below. Keep case IDs and group membership. Do not
rebalance jobs or select the final PR cases yet.

## Current group audit

The inventory comes from `tools/ci_matrix.json`, the current generated catalog,
and the case definitions. It uses current group membership, not the historical
31-case table/column/index inventory. Database defaults now belong to the database
group. Row keys, key conflicts and grouped constraints belong to `keys-rows-gtids`.

All IDs below use the `ddl-compat-` prefix unless shown otherwise.

| Cases | Current execution | Completion record |
|---|---|---|
| `generated`, `generated-expressions` | Retained tables and final observations; expression restarts and replay remain. | [Generated columns](BETA7_GENERATED_COLUMN_WORKFLOW_REVIEW.md) |
| `generated-dependencies`, `column-swaps` | Retained definitions and key/column states; eight live restarts and both replay paths remain. | [Dependencies and swaps](BETA7_DEPENDENCY_SWAP_WORKFLOW_REVIEW.md) |
| `column-index-syntax`, `alter-column-keys` | Retained key/SERIAL/rebuild states; five live restarts and both replay paths remain. | [Column keys](BETA7_COLUMN_KEY_WORKFLOW_REVIEW.md) |
| `column-renames`, `alter-table-rename`, `multi-table`, `cross-schema-relationships` | Retained table states and final observations; required rename, cross-schema and FK boundaries remain. | [Current table/column/index plan](BETA7_TABLE_COLUMN_INDEX_REVIEW.md) |
| `fulltext`, `spatial-prefix-indexes`, `json-indexes` | Batched changes and final observations; parser, prefix and generated-index conditions remain. | [Index workflows](BETA7_INDEX_WORKFLOW_REVIEW.md) |
| `ignored-checks`, `alter-options`, `table-options`, `table-maintenance` | Retained options/maintenance states; version and engine branches remain. | [Table options](BETA7_TABLE_OPTIONS_WORKFLOW_REVIEW.md) |
| `alter-conversions`, `types`, `alter` | Retained definitions and converted values; timestamp/session behavior remains. | [Column conversions](BETA7_COLUMN_CONVERSION_WORKFLOW_REVIEW.md) |
| `ddl-modify-columns` | Shared preparation and running applier; batched observations, normalized binlogs and saved schema/transaction checks. | [MODIFY pilot](BETA7_TABLE_COLUMN_INDEX_REVIEW.md#first-implementation-slice-modify-columns) |

The audit is saved in `artifacts/table-column-index-completion/group-audit.json`.
It records each source file, execution form, restart count and default-profile
applicability. Existing exclusions still apply. Completion means the local
conversions passed their selected tests, not that every profile was rerun.

Do not remove deliberate restarts to reduce the count of batches. Do not move
negative, recovery or keyless-recovery workflows into this completed group.
They have different state boundaries and feature owners. Those areas still need
review under Slice 3; they are not part of this completion claim.

## Next area: partition management

Partition management has 11 declared cases. The saved default-profile CI data
contains 41 successful executions: 11 forward and ten on each other profile.
The `partition-rename-syntax` case is not applicable to 5.7 sources. This is an
existing exclusion, not a missing result.

Use MySQL's names for partition types and operations. Consult these manuals when
naming or extending the workflows:

- [Management of RANGE and LIST Partitions](https://dev.mysql.com/doc/refman/8.4/en/partitioning-management-range-list.html)
- [Management of HASH and KEY Partitions](https://dev.mysql.com/doc/refman/8.4/en/partitioning-management-hash-key.html)
- [Exchanging Partitions and Subpartitions with Tables](https://dev.mysql.com/doc/refman/8.4/en/partitioning-management-exchange.html)

Start with these existing case IDs and proposed titles:

- `ddl-compat-partitions`: **Partition management: RANGE COLUMNS and EXCHANGE PARTITION**.
- `ddl-compat-hash-list`: **Partition management: HASH, KEY and LIST changes**.

They have ten and seven source operations. Neither has `restartBefore` flags or
a case-specific offline replay call. Keep the shared checkpoint, completed-DDL
and saved-schema restart checks. Do not add an offline replay sequence as part
of this execution-only change. Other partition cases already test that behavior.

Both cases set `nativeInnoDB: true`. Keep that setting. On a MyISAM target
profile, the native reference uses InnoDB for these cases. The existing runner
sets its engine before the case and compares the declared engine on each role.
Do not change the native SQL-thread engine transition in this slice.

### Baseline

Source inspection confirms both case bodies are unchanged since successful
CI run `40454033524`, commit `efb3458`. The saved summary/report is complete.
Values below are **case seconds / harness SQL client calls** for default SQL.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| RANGE COLUMNS/exchange | 23.39 / 165 | 23.51 / 164 | 24.35 / 164 | 18.17 / 164 |
| HASH/KEY/LIST | 18.41 / 117 | 18.75 / 116 | 18.97 / 116 | 14.49 / 116 |

The forward pair uses 282 client calls and 41.80 case seconds. These are not
applier SQL counts. Coverage belongs to the whole partition group, not to either
case. Do not claim that this pair replaces other partition conditions based on
overlap. Its simpler state transitions make it a useful first conversion before
cases with encoded bounds, algorithm changes, unlogged operations and replay.

Evidence is saved in `artifacts/table-column-index-completion/partition-baseline.json`
and `partition-pilot.json`. The first contains all 41 default-profile results.
The second contains the unchanged source SQL, eight explicit predicates and
retained-prefix maps for the proposed pair.

### RANGE COLUMNS and exchange: retained states

Keep all ten original operations first. Retain prefixes 2 through 9 on separate
table sets. For prefixes 6–9, replace both `ddlcompat.t` and `ddlcompat.stage`
with distinct names for that set. Preserve partition names and bounds. Do not
copy final rows instead of executing DROP, TRUNCATE, REORGANIZE or EXCHANGE.

| Prefix | State to retain and compare |
|---|---|
| 2 | Three seeded rows and all original RANGE COLUMNS bounds. |
| 3 | DROP removes ID 1 and its partition; IDs 2 and 3 remain. |
| 4 | TRUNCATE empties `current_data` but retains its definition; only ID 3 remains. |
| 5 | REORGANIZE splits the future range; preserve both new bounds and row placement. |
| 6 | Same partitioned table and newly created empty exchange table. |
| 7 | Exchange table contains ID 4; partitioned table still contains ID 3. |
| 8 | EXCHANGE WITH VALIDATION moves ID 4 into `t` and ID 3 into `stage`. Check both sides before the UPDATE. |
| 9 | UPDATE changes ID 4's value to 41; ID 3 remains in the exchange table. |
| Original final state | REMOVE PARTITIONING leaves ID 4/value 41 in `t`; no named partitions remain. The original exchange table retains ID 3. |

The retained prefixes add 44 operations and 12 tables. With the original ten,
there are 54 operations in one body batch. Keep all six existing query
predicates and exact expected values, with only table names changed. Add named
checks for seed rows, the empty stage and required partition membership. The
full schema/row comparison must preserve bounds, partition names and both
exchange-table results. Cleanup removes only the added retained tables after
saved-state checks; original `t` and `stage` remain as before.

### HASH, KEY and LIST: retained states

Keep all seven original operations first. Retain prefixes 2 through 6 on five
separate tables. The original final table provides the result after INSERT
into the newly added LIST partition.

| Prefix | State to retain and compare |
|---|---|
| 2 | HASH with four partitions; rows 1/10 and 2/20. |
| 3 | COALESCE to two partitions; sum remains 30. |
| 4 | Repartition by KEY with two partitions; both rows remain. |
| 5 | Repartition by LIST with `p1` and `p2`; keep value lists and row placement. |
| 6 | ADD empty partition `p3`; existing rows and partitions remain. |
| Original final state | INSERT adds ID 3/value 30 in `p3`; sum is 60. |

The retained prefixes add 20 operations and five tables. With the original
seven, there are 27 operations in one body batch. Keep both existing sum
predicates. Add explicit rows and partition metadata/selection checks so equal
sums cannot hide missing or moved rows. Do not assert undocumented HASH/KEY
bucket membership; preserve the existing native comparison and test partition
counts/methods. Cleanup removes only retained tables after saved-state checks.

## Next implementation and local validation

1. Extract these two inline definitions into a partition-workflow source file.
   Keep IDs, source order, session resets, transaction counts, profile selection
   and `nativeInnoDB: true`. Add one final-observation plan per case. Keep the
   original tables after the workflow and list added tables for cleanup.
2. Add focused unit checks for the two maps above, both-table name substitution
   during exchange, eight retained original predicates, partition metadata,
   transaction counts and absence of added live restarts. Keep the common
   source-phase and final-observation checks. No runtime parser change is needed.
3. Check the DDL catalog, feature/migration rules and matrix. Keep 183 jobs,
   1,545 obligations and 182 coverage collections. These cases have no retired
   migration assertions. Do not add jobs or change the short PR selection.
4. Build one matching coverage image and run the pair in one forward
   MyISAM/default/SQL fixture:

   ```sh
   make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-partitions --case ddl-compat-hash-list --coverage"
   ```

5. Verify source/native/target results, transaction counts, GTIDs/file offsets,
   completed DDL intents, saved-schema restart, cleanup and coverage export.
   Check a support bundle first if the applier fails. Record source-operation
   counts, SQL client calls and time. Added histories increase source work.
6. Update the test guide and plan with measured results. Stop after this pair
   passes. Defer other profiles to CI unless a new version/engine branch or
   failure needs a second local profile. Do not rerun the completed table group,
   syntax tests, benchmarks or the full suite.

## Remaining partition review and overall sequence

After the pair passes, review the other nine partition cases in related slices:

- Partition/subpartition forms and bound expressions: preserve routing and
  evaluated-bound assertions before later repartitioning replaces them.
- Column renames and partition-column bounds: preserve version-specific syntax,
  byte encodings, source session settings and existing replay stops.
- KEY algorithms, unchecked exchange and maintenance: retain algorithm metadata,
  recovery/state assertions, native engine behavior and zero-transaction
  CHECK/LOCAL operations. Do not treat each source statement as one transaction.

Then review stored objects, character sets/collations, data types and row-key/index
operations, as required by Slice 3. Balance jobs using one later full instrumented
CI run. Select the final short PR list after that comparison. Do not infer new
whole-group timings by adding measurements from different local runs.


## Partition pilot: implementation and focused results

The two inline cases now live in `PartitionWorkflowCases.swift`. Each uses one
body batch and a final-observation plan. The original 17 operations remain first
and unchanged. All eight original explicit predicates remain, with retained
table names where needed. The RANGE case executes 54 operations; HASH/KEY/LIST
executes 27. No live restart or offline replay sequence was added.

Both cases passed in one forward MyISAM/default/SQL fixture with coverage:

| Case | Saved CI client calls | New client calls | Local case seconds | Named assertions |
|---|---:|---:|---:|---:|
| RANGE COLUMNS/exchange | 165 | 33 | 12.68 | 23 |
| HASH/KEY/LIST | 117 | 32 | 11.63 | 18 |

The combined call count is 65, down from 282 in the saved CI run. These are
harness SQL client calls, not statement counts. Retained histories increase
source operations. The old times came from CI and the new times came from a
local machine; they do not establish a controlled elapsed-time speedup.

All 41 named assertions passed. They include the 35 explicit final queries,
two full schema/row comparisons and both source body batches. The snapshot
checks confirm the source-operation counts, final applied groups, file offsets
and completed DDL intents. Saved-schema restart, cleanup and coverage export
passed. The raw table comparisons confirm InnoDB on the source/native servers
and MyISAM on the target, across 14 RANGE/exchange tables and six HASH/KEY/LIST
tables. Cleanup removes the retained tables and keeps the original case tables.

The fixture used six source phases: two body batches, two setup batches and
two cleanup batches. Setup took 14.80s, including 12.22s for container startup
and 2.19s for database setup. Coverage export took 2.67s. Cleanup took 10.75s.
The coverage-image build step took 229.5s and reused dependency layers.

Combined runtime coverage was 8,523 of 20,880 mapped lines. The saved CI coverage
includes all applicable partition cases, so it cannot establish per-case parity
for this pair. The source and assertion maps preserve the tested conditions.
The remaining nine partition cases were not rerun locally.

All 50 focused Swift tests and 18 feature/migration tool tests passed. The DDL
catalog check passed. The matrix keeps 183 jobs, 1,545 obligations and 182
coverage collections, with the same execution groups and profile exclusions.
No other profile, full suite, syntax suite or benchmark ran.

Evidence:

- `artifacts/lab/20261030T214824Z-a6c4714d/result.json`
- `artifacts/partition-workflow-review/results.json`
- `artifacts/partition-workflow-review/state-results.json`
- `artifacts/partition-workflow-review/source-preservation.json`
- `artifacts/partition-workflow-review/matrix-comparison.json`
- `artifacts/partition-workflow-review/unit.log`

The [partition forms conversion](BETA7_PARTITION_FORMS_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed all three cases in one forward MyISAM/default/SQL fixture. It keeps the
15 original predicates, eight live restarts and both offline replay paths.
All 136 named assertions, saved-schema restart and cleanup passed. Harness SQL
client calls fell from 638 in saved CI to 195 locally. The matrix is unchanged.

The [partition rename/bounds conversion](BETA7_PARTITION_RENAME_BOUNDS_REVIEW.md#implementation-and-focused-results)
passed all three cases in one forward MyISAM/default/SQL fixture. All 120 named
assertions, eight live restarts, three replay stop/resume checks, saved-schema
restart and cleanup passed. Harness SQL client calls fell from 649 in saved CI
to 242 locally. The original SQL, byte predicates and matrix remain intact.

The [partition administration conversion](BETA7_PARTITION_ADMINISTRATION_REVIEW.md#implementation-and-focused-results)
passed all three cases across two focused forward MyISAM/default/SQL fixtures.
All 105 named assertions, seven restarts, both replay paths and five unlogged
boundary checks passed. Client calls fell from 591 in saved CI to 185 locally.
The original SQL, predicates and matrix remain intact.

The [partition completion audit](BETA7_PARTITION_ADMINISTRATION_REVIEW.md#partition-area-local-completion-audit)
confirms all 11 cases use final observations, with 34 body batches and 23 live
restarts. Local partition conversion work is complete. Full-matrix validation
and whole-group timing remain for CI.

The [stored-object pilot](BETA7_STORED_OBJECT_WORKFLOW_REVIEW.md#pilot-implementation-and-focused-results)
passed both views/routines cases in one forward MyISAM/default/SQL fixture.
All 23 named assertions, original absence checks, compound-body checks,
saved-schema restart and cleanup passed. Client calls fell from 222 in saved CI
to 78 locally. The eight original predicates and matrix remain intact.

The [stored-object ALTER conversion](BETA7_STORED_OBJECT_ALTER_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 52 named assertions,
three restarts, replay stop four/resume 79, the three original journal records,
saved-schema restart and cleanup passed. Client calls fell from 263 in saved CI
to 86 locally. The 11 original predicates and matrix remain intact.

The [view rename conversion](BETA7_VIEW_RENAME_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 50 named assertions,
three restarts, replay stop seven/resume 77, four original journal records,
view/base-table cache checks, error 1450 checks, saved-schema restart and cleanup
passed. Client calls fell from 251 in saved CI to 97 locally. The 11 original
predicates and matrix remain intact.

The [conditional routine conversion](BETA7_CONDITIONAL_ROUTINE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 38 named assertions,
two live restarts, replay stop four/resume 50, original journal counts five/two,
saved-schema restart and cleanup passed. Captured source GTIDs select the original
journal records because MySQL changes stored routine SQL formatting. Client calls
fell from 186 in saved CI to 79 locally. All six original predicates and the matrix
remain intact.

The [absent definer conversion](BETA7_ABSENT_DEFINER_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its focused forward MyISAM/default/SQL fixture. All 38 named assertions,
two restarts, replay stop four/resume 13 and twelve ERROR 1449 checks passed.
Each error left GTIDs/offsets unchanged. Both error stages have separate evidence.
Saved-schema restart and cleanup passed. SQL trace calls fell from 177 in saved
CI to 111 locally; both totals include the twelve expected failures. All four
original predicates and the matrix remain.

The [executable-comment conversion](BETA7_EXECUTABLE_COMMENT_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed its two focused default/SQL fixtures: main/target-version on forward
MyISAM, source-version on reverse InnoDB. All 39 named assertions, four restarts,
three replay paths, original journal records, role-specific comments,
saved-schema restarts and cleanup passed. SQL trace calls fell from 359 in saved
CI to 188 locally. Original predicates, comment bytes and profile selections
remain.

The [temporary-table conversion](BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed both focused fixtures: 43 named assertions, retained row checks, engine
variants, permanent `tmp` rows, 5.7 cleanup audit, restart/replay and cleanup.
Source counts remain observed: the 12-operation SELECT workflow produced 17
transactions on 5.7. Exact replay offsets passed. SQL trace calls fell from 438
in saved CI to 173 locally. The permanent CTAS contract is unchanged. The
[group audit](BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#stored-object-group-local-completion-audit)
finds all 11 cases converted with the same profile selections.

The [first character-set slice](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#first-slice-implementation-and-focused-results)
passed table defaults and compound CONVERT/default clauses together on forward
MyISAM. All 26 named assertions, seven original predicates, four restarts,
exact GTIDs/offsets, saved-schema restart and cleanup passed. SQL trace calls fell
from 335 in saved CI to 111 locally. Matrix and profile selections remain.
The [charset-conversion results](BETA7_CHARSET_CONVERSION_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the focused forward MyISAM case. All 17 named assertions passed.
Four batches retain six old predicates, three restarts, FULL metadata and exact
GTID/file offsets. SQL client calls changed from 222 in saved CI to
73 locally. The [DEFAULT workflow results](BETA7_CHARSET_DEFAULTS_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the reverse case with all 17 named assertions. Five batches preserve
unselected-database statements, logged collation overrides, four old predicates
and INSERT/UPDATE row states. Captured Query events confirm the session contexts.
SQL client calls changed from 168 in saved CI to 64 locally.
The [encoded Query workflow](BETA7_QUERY_IDENTIFIER_WORKFLOW_REVIEW.md#encoded-query-implementation-and-focused-results)
passed the forward MyISAM case with all 15 named assertions. Three batches
retain four old predicates, both restarts, FULL metadata and the added-column
value before UPDATE. Captured events confirm 12 exact non-UTF-8 DDL payloads
and 13 following UTF-8 row/DROP sessions. SQL client calls changed from
217 in saved CI to 62 locally. The [Unicode table-name workflow](BETA7_UNICODE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the forward case with all 20 named assertions. One body batch preserves
all original names, four old predicates, pre-update/renamed/LIKE rows and DROP
outcomes. Saved state confirms nine current tables with exact bytes and retired
names. SQL client calls changed from 213 in saved CI to 60 locally.
The [lower-case table-name workflow](BETA7_LOWERCASE_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the forward lowercase-tables case with all 21 named assertions. Three
batches preserve mixed-case references, both old predicates, both restarts and
earlier ADD/copy rows. Runtime evidence confirms mode 1 on all three servers.
SQL client calls changed from 160 in saved CI to 74 locally. The
[DML identifier workflows](BETA7_DML_IDENTIFIER_WORKFLOW_REVIEW.md#unicode-implementation-and-focused-results)
passed their focused forward cases: 16 ASCII assertions and 20 Unicode assertions.
Both keep the original SQL and metadata inputs, check GTID intervals and add no
applier restart. Next: review the native collation/encoding inventories with
explicit value and ID maps, then ENUM/SET. Keep remaining type/value and key/index
reviews, full-matrix validation, final balancing and short PR selection later.
