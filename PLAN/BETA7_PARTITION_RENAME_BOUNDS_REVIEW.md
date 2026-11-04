# Partition column renames and column bounds: workflow review

## Decision

Convert these three cases to source batches and final observations. Keep their
IDs, Partitions feature owner and `ddl-partition-management` group. Keep separate
case results in one shared fixture.

| Case suffix after `ddl-compat-` | Suggested title | Original operations | Body batches | Live restarts | Replay stop |
|---|---|---:|---:|---:|---:|
| `partition-column-renames` | ALTER TABLE: CHANGE columns with partition replacement and removal | 13 | 5 | 4 | 5 |
| `partition-rename-syntax` | ALTER TABLE: RENAME COLUMN with partition replacement and removal | 7 | 3 | 2 | 5 |
| `partition-column-bounds` | RANGE COLUMNS and LIST COLUMNS: binary, character and date bounds | 13 | 3 | 2 | 3 |

Keep all 33 original operations first in each case. Keep all 18 explicit query
predicates, eight live restarts and three replay stop/resume paths. Append
independent tables that retain states which later statements change or drop.
Do not combine source transactions.

The review used saved SQL, assertions and timings. Implementation and focused
validation are now complete; results follow below. The preceding partition
forms conversion was committed as `b463e03`.

## Names and scope

Consult the MySQL manual before changing feature names. Use
[ALTER TABLE](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html),
[RANGE COLUMNS partitioning](https://dev.mysql.com/doc/refman/8.4/en/partitioning-columns-range.html)
and [Character Set Introducers](https://dev.mysql.com/doc/refman/8.4/en/charset-introducer.html).

The first case renames columns used in partition and subpartition expressions.
It does not rename the subpartitions themselves. Its current title, "Column and
subpartition renames", is ambiguous. Use the title above.

Keep CHANGE and RENAME COLUMN as distinct source syntax. The latter case retains
all three exclusions for MySQL 5.7 sources. Keep `nativeInnoDB: true` on all
three cases. Do not remove binary/character-bound checks because another case
also inserts or updates rows: these predicates check placement and exact bytes.

## Saved measurements

Successful CI run `40454033524`, commit `efb3458`, has a complete report with no
failed shards, missing shards or missing coverage. `PartitionRenameCases.swift`
and `PartitionColumnCases.swift` still match that commit exactly. All nine
applicable default/profile results passed.

Each cell below is **case seconds / harness SQL client calls**:

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| CHANGE columns | 54.02 / 226 | 53.91 / 225 | 54.56 / 225 | 44.65 / 225 |
| RENAME COLUMN | 32.38 / 132 | Not applicable | Not applicable | Not applicable |
| Column bounds | 48.93 / 291 | 49.42 / 290 | 50.16 / 290 | 38.42 / 290 |

The forward selection used 649 client calls. These are harness calls, not
applier target statements. The current runner waits and compares schemas and
rows after every operation. The proposal replaces 33 per-operation observation
points with 11 body batches and three final observation sets.

Saved coverage belongs to the full partition group. It cannot establish which
lines each case supplied. No evidence supports removing these cases as redundant.
Use the SQL and predicate map to preserve their distinct conditions.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/partition-rename-bounds-review/baseline.json`: nine saved results.
- `artifacts/partition-rename-bounds-review/source-review.json`: original SQL,
  predicates, restart points, proposed retained prefixes and batch sizes.
- `artifacts/partition-rename-bounds-review/review.py`: reproducible source audit.

## CHANGE columns with partition replacement and removal

Keep all 13 original operations, including the final DROP. Restarts remain before
operations 3, 5, 7 and 9. Retain prefixes 1–2 through 1–12 on 11 independent tables.
Change only qualified table names; do not change column names in copied SQL.

| Last original operation | Suggested retained table | Required observation |
|---:|---|---|
| 2 | `pc_seed` | Original `a,b,n` columns, composite PRIMARY KEY, RANGE/HASH definitions and two seed rows. |
| 3 | `pc_changed` | Columns `x,y,n`; partition expression `x`, subpartition expression `y`; rows `1,10,100` and `11,20,200`. |
| 4 | `pc_moved` | Both rows in `p1`: `11,20,200` and `21,30,101`; old `p0` is empty. |
| 5 | `pc_swapped` | Simultaneous `x`/`y` swap; partition expression `y`, subpartition expression `x`; unchanged values through the renamed columns. |
| 6 | `pc_inserted` | New row `2,3,4` is in `p0` after the swap. |
| 7 | `pc_removed` | Columns `id,sid,n`; no partitioning; rows and composite key remain. |
| 8 | `pc_implicit_key` | Implicit `KEY()` partitioning on the composite PRIMARY KEY. |
| 9 | `pc_key_renamed` | Column and key reference `key_id`; exact three-row predicate remains. |
| 10 | `pc_updated` | Value 201 for `key_id=11,sid=20`, before removal of partitioning. |
| 11 | `pc_final_name` | Column `final_id`; partitioning removed; rows before DELETE remain. |
| 12 | `pc_deleted` | Exact remaining rows `11,20,201` and `21,30,101`. |

Keep all seven original predicates, with retained table names where necessary.
Add an explicit check that original table `t` was dropped. Compare all retained
columns, PRIMARY KEY parts, partition definitions and rows against source/native.

The shared comparison does not read subpartition expressions. Add case-local
final queries for expressions after CHANGE and after the simultaneous swap.
Use the known expected column names. Do not change the shared schema comparison
in this slice. Do not hard-code a KEY partition expression to `id,sid`: implicit
`KEY()` can report an empty expression. Preserve the source syntax and compare
its resulting schema with native.

This proposal has 90 operations in batches of 2, 2, 2, 2 and 82. The original
DROP remains operation 13. Cleanup removes only the 11 retained tables.

## RENAME COLUMN with partition replacement and removal

Keep all seven original operations and the three existing profile exclusions.
Restarts stay before operations 3 and 5. Retain prefixes 1–2 through 1–6:

| Last original operation | Suggested retained table | Required observation |
|---:|---|---|
| 2 | `ps_seed` | Initial RANGE partitions and seed rows. |
| 3 | `ps_renamed` | `renamed` column and partition expression; exact rows `1,10` and `11,20`. |
| 4 | `ps_moved` | High partition rows `11,20` and `21,10`; low partition is empty. |
| 5 | `ps_removed` | Column restored to `id`; no partitioning; both rows remain. |
| 6 | `ps_deleted` | Only row `21,10` remains after DELETE. |

Keep all three original predicates. Add an explicit check that original `t` was
dropped. The full comparison checks translated column metadata and all retained
rows. Preserve the original RENAME COLUMN SQL; do not rewrite it in the fixture.
The applier's existing target translation remains the subject of the test.

This proposal has 27 operations in batches of 2, 2 and 23. Cleanup removes only
the five retained tables.

## RANGE COLUMNS and LIST COLUMNS bounds

Keep all 13 original operations. Restarts stay before operations 4 and 9.
Only original table `t` loses intermediate results. The other four tables remain
available at the end. Retain only these three prefixes:

| Original sequence | Suggested retained table | Required observation |
|---|---|---|
| 1–2 | `pb_seed` | Binary bound `X'80FF'`; low rows `0080,1` and `80FE,2`; rows equal to and above the bound remain in `q`. |
| 1–3 | `pb_reorganized` | New `_binary X'F0'` bound; original rows remain after REORGANIZE. |
| 1–4 | `pb_moved` | Updated key `X'81'` moves into `middle`; exact rows `80FF,3` and `81,2` there before DELETE. |
| Original final `t` | No extra table | DELETE removes `X'FF'`; exact remaining bytes and values. |
| Original final `s` | No extra table | latin1 LIST values, `_latin1 X'E9'`, and the trailing-space literal `'a  '`; exact routing predicate. |
| Original final `d` | No extra table | Source DATE spelling `'20260101'`; tuple boundary puts ID 9 in `p`, ID 10 in `q`. |
| Original final `encoded` | No extra table | Connection character set and introducer produce distinct `C3A9` and `E9` values. |
| Original final `b` | No extra table | Empty bytes, `005C0A27`, `2A2F` and `FF`, with exact lengths and HEX values. |

Keep all eight original predicates. Preserve their whitespace, including the
empty HEX field in `0\t`. Keep HEX/LENGTH checks and the shared raw-byte schema
comparison. For binary COLUMNS bounds, that comparison reads `SHOW CREATE TABLE`
with `SET NAMES binary` and uses `NativeChoiceDefinition.partitionBounds`. Do not replace this
path with display text from INFORMATION_SCHEMA alone.

Operation 10 contains `SET character_set_connection=latin1; CREATE TABLE ...`.
Keep both statements in one source operation. Keep the literal `é` and its
`_latin1` introducer exactly as written. Do not replace them with equivalent hex
SQL: that would remove the source text-encoding condition.

The current batch runner already resets the source session before each operation:
`LabSQLPhase.queries` prepends `LabProfile.session`, including `SET NAMES utf8mb4
COLLATE utf8mb4_bin`. Thus operation 10 overrides the connection character set
for its CREATE, and operation 11 starts with the normal session again. Add a
focused unit guard for this order. No new production session behavior is needed.

This proposal has 22 operations in batches of 3, 5 and 14. Cleanup removes only
`pb_seed`, `pb_reorganized` and `pb_moved`. Keep all five original tables.

## Replay and saved state

Keep all three existing replay paths. Pass `finalObservations` and the case ID
to the calls in `SharedCorrectness.swift`.

- CHANGE case: stop after operation 5, the simultaneous column swap and partition replacement.
- RENAME COLUMN case: stop after operation 5, the rename and REMOVE PARTITIONING.
- Column-bounds case: stop after operation 3, REORGANIZE with `_binary X'F0'`.

Keep the original SQL first so these stop points still select the same changes.
Both rename cases currently end with DROP, so their final replay comparison sees
an empty database. Retained tables let the final replay comparison also check
earlier rows and partition definitions. Run all final predicates after resume.
Keep the original GTID/file-offset, DONE-intent and saved-schema checks. Cleanup
must follow these checks and replay, not remove evidence before they run.

## Implementation and validation order

1. Convert the three cases with the existing phase and final-observation helpers.
   Preserve the eight restarts, source order and separate transaction boundaries.
   Extend the three existing replay calls. Keep the matrix and exclusions.
2. Add focused unit tests for original SQL, all 18 predicates, batch sizes,
   table isolation, final DROP checks and cleanup. Verify the session reset
   around the latin1 CREATE and preserve the literal bytes and trailing spaces.
   Run these tests plus affected phase/final-observation/session helper tests.
3. Run only these three cases together, once, on forward MyISAM/default/SQL with
   coverage. This profile exercises the RENAME COLUMN translation and all three
   cases. Use one fixture. Check all replay stops/resumes, GTIDs, offsets,
   saved schemas, completed intents and cleanup. On failure, read the support
   bundle before rerunning the failed case.
4. Compare the matrix/catalog and record client calls. Report setup, case,
   coverage-export and cleanup time separately. Use source/predicate audits;
   do not claim per-case coverage parity against the saved full partition group.
5. Leave the other profiles and full suite to CI. Add a second local profile
   only if a new version/engine branch or failure requires it. Do not run the
   syntax suite or benchmarks for this lab-only conversion.

Focused integration command for the implementation step:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-partition-column-renames --case ddl-compat-partition-rename-syntax --case ddl-compat-partition-column-bounds --coverage"
```

After this slice, review KEY algorithms, unchecked exchange and partition
maintenance. Preserve their saved-state checks and zero-transaction operations.
Then continue the remaining feature areas in the overall consolidation plan.
Do not rebalance jobs or choose the final short PR selection yet.


## Implementation and focused results

The three cases now use 11 body batches and final observations. All 33 original
operations and 18 original predicates remain. The original DROP statements keep
their positions. All eight live restarts and three replay stops remain. Source
statements keep their separate transaction boundaries. Production replication
code did not change.

All three cases passed in one forward MyISAM/default/SQL fixture with coverage:

| Case | Saved CI client calls | New client calls | Local case seconds | Named assertions |
|---|---:|---:|---:|---:|
| CHANGE columns | 226 | 81 | 49.23 | 54 |
| RENAME COLUMN | 132 | 62 | 29.69 | 26 |
| Column bounds | 291 | 99 | 33.44 | 40 |

The combined client count fell from 649 to 242. These are harness calls, not
applier target statements. Old timings came from CI and new timings came from
a local machine. They do not establish a controlled elapsed-time speedup.

All 120 named assertions passed. These include 46 explicit final queries,
49 replay queries/comparisons, the eight live restarts and full schema/row
comparisons. Replay stopped after transactions five, five and three. It resumed
to all 90, 27 and 22 source operations. Read-only SQLite and summary checks
confirmed the GTID sets, final file offsets, applied groups, DONE DDL intents
and retired schemas for the two original dropped tables. Replay used an
unreachable source address.

Full comparisons covered 11 CHANGE tables, five RENAME COLUMN tables and eight
column-bound tables. Raw table metadata confirmed InnoDB on source/native and
MyISAM on target. Exact byte, trailing-space, tuple-routing and subpartition
reference checks passed. The latin1 override remains in its original CREATE
operation. Unit checks confirm that the next operation resets the session.
Retained-table cleanup and the shared saved-schema restart passed.

The first local attempt found a harness assertion-name conflict: a source phase
and a final check both used `seed-rows`. The two phases now use `create-and-seed`.
A unit guard checks that phase names and final-check names do not overlap.
The harness support bundle confirmed no active GTID or pending DDL. The failed
run and bundle remain under `artifacts/lab/20261103T015416Z-4173b7a6`.

The successful fixture used 17 source phases: 11 body batches, three setup
batches and three cleanup batches. Setup took 14.08s, including 11.18s for
container startup and 2.28s for database setup. Coverage export took 12.56s.
Fixture cleanup took 11.72s. Dependency build layers were reused.

Combined runtime coverage was 9,854 of 20,880 mapped lines. Saved CI coverage
covers the full partition group, so it cannot establish per-case parity for
this selection. The source and predicate audits confirm the retained conditions.

All 21 focused Swift tests and 18 feature/migration tool tests passed. The DDL
catalog, formatting and matrix checks passed. The matrix keeps 183 jobs,
1,545 obligations and 182 coverage collections, with the same execution groups
and profile exclusions. No other profile, full suite, syntax suite or benchmark
ran. The test guide now explains this three-case selection.

Evidence:

- `artifacts/lab/20261103T020310Z-14ac257a/result.json`
- `artifacts/partition-rename-bounds-review/results.json`
- `artifacts/partition-rename-bounds-review/state-results.json`
- `artifacts/partition-rename-bounds-review/source-preservation.json`
- `artifacts/partition-rename-bounds-review/matrix-comparison.json`
- `artifacts/partition-rename-bounds-review/unit.log`

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
Next: review the lower-case table-name variant, then DML identifier phases. Keep
native inventories, full-matrix validation, final balancing and short PR selection later.
