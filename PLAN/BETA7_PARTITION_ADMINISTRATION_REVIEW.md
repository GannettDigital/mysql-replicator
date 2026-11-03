# KEY algorithms, unchecked exchange and partition maintenance: workflow review

## Decision

Convert the three remaining partition cases to source batches and final
observations. Keep their IDs, Partitions feature owner, profiles and
`ddl-partition-management` group. Keep separate results in one shared fixture.

| Case suffix after `ddl-compat-` | Suggested title | Original operations | Body batches | Live restarts | Offline replay stop |
|---|---|---:|---:|---:|---|
| `partition-key-algorithm` | KEY partitioning: algorithms, partition placement and CREATE LIKE | 13 | 4 | 3 | Transaction 3 |
| `partition-exchange-unchecked` | EXCHANGE PARTITION WITHOUT VALIDATION: misplaced rows and exchange back | 13 | 3 | 2 | Transaction 5 |
| `partition-maintenance` | Partition maintenance: logged operations, CHECK and LOCAL | 9 | 3 | 2 | None today; do not add one |

Keep all 35 original operations first in each case. Keep all 13 explicit query
predicates, seven live restarts and both replay stop/resume paths. Preserve the
zero-transaction declarations on CHECK and LOCAL, including retained copies.
Do not combine source transactions.

The review used saved evidence. Implementation and focused validation are now
complete; results follow below. The preceding rename/bounds conversion was
committed as `5199237`.

## Names and scope

Consult MySQL documentation before changing feature names. Use
[KEY Partitioning](https://dev.mysql.com/doc/refman/8.4/en/partitioning-key.html),
[Exchanging Partitions and Subpartitions with Tables](https://dev.mysql.com/doc/refman/8.4/en/partitioning-management-exchange.html)
and [Maintenance of Partitions](https://dev.mysql.com/doc/refman/8.4/en/partitioning-maintenance.html).

Keep `nativeInnoDB: true` on all three cases. The forward native reference uses
InnoDB for these partition cases, while the external target uses MyISAM. Keep
warnings and command results available. Do not require identical physical repair
behavior across engines or require all maintenance warnings to be empty.

## Saved measurements

Successful CI run `40454033524`, commit `efb3458`, has a complete report with no
failed shards, missing shards or missing coverage. All three case definitions
still match that commit. All 12 default/profile results passed.

Each cell below is **case seconds / harness SQL client calls**:

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| KEY algorithms | 47.43 / 224 | 48.54 / 223 | 49.20 / 223 | 40.04 / 223 |
| Unchecked exchange | 41.17 / 219 | 41.87 / 218 | 41.99 / 218 | 33.25 / 218 |
| Partition maintenance | 32.64 / 148 | 32.99 / 147 | 33.68 / 147 | 27.68 / 147 |

The forward selection used 591 client calls. These are harness calls, not
applier target statements. The proposal replaces 35 per-operation observation
points with 10 body batches and three final observation sets.

Saved coverage belongs to the full partition group. It cannot establish which
lines each case supplied. Their assertions differ, so overlapping group coverage
does not justify removing any case.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/partition-administration-review/baseline.json`: 12 saved results.
- `artifacts/partition-administration-review/source-review.json`: SQL, predicates,
  restart points, transaction declarations and proposed retained sequences.
- `artifacts/partition-administration-review/review.py`: reproducible source audit.

## KEY algorithms

Keep the 13 original operations. Restarts stay before operations 4, 9 and 13.
The original `t`, `copy` and `sub` tables remain available at the end.

| Retained original sequence | Suggested table | Required observation |
|---|---|---|
| 1–2 | `ka_seed` | ALGORITHM=1; IDs `1,5,9,13` in `p0`; all 16 seed rows. |
| 1–3 | `ka_truncated` | Twelve rows with sum 1080; `p0` empty after TRUNCATE. |
| 1–4 | `ka_added` | Six KEY partitions and unchanged remaining rows. |
| 1–5 | `ka_coalesced` | Four KEY partitions and unchanged remaining rows. |
| 1–6 | `ka_algorithm_two` | ALGORITHM=2 before the original sequence replaces it. |
| 10–11 | `ka_sub_seed` | Initial RANGE/KEY subpartitions; ID 1 in `psp0`. |
| 10–12 | `ka_sub_reorganized` | Low/high partitions with four KEY subpartitions each; rows before UPDATE. |
| Original final tables | No extra tables | ALGORITHM=1 restored on `t`; CREATE LIKE copy has the same rows; updated `sub` rows and ID 1 in `lowsp0`. |

Keep all six original predicates. The subpartition retained sequences start at
operation 10. Do not include unrelated `t` or `copy` operations in those copies.

Keep both existing SQLite checks on the original names: `t` and `copy` must
store partition key algorithm 1; `sub` must store subpartition key algorithm 1.
The shared INFORMATION_SCHEMA comparison does not read the algorithm number.
Add a check that current saved schema `ka_algorithm_two` represents algorithm 2.
The schema format omits the default algorithm 2; interpret the absent field as
2 for this KEY table. Algorithm 1 remains explicit.
Keep placement queries and compare all rows/definitions against source/native.
Do not claim that this covers every data type's KEY hashing behavior.

The proposal has 38 operations and transactions, with batch sizes 3, 5, 4 and 26.
It adds seven retained tables. Keep replay label `partition-key`, stop after
transaction 3, and pass final observations and the case ID to replay. Cleanup
must remove only the seven retained tables after saved-state/replay checks.

## EXCHANGE PARTITION WITHOUT VALIDATION

Keep all 13 original operations and restarts before operations 6 and 10.
Retain prefixes 1–4 through 1–12. Each prefix needs its own main table and
exchange table, for example `ex_misplaced` and `ex_misplaced_stage`.

| Last original operation | Required retained state |
|---:|---|
| 4 | Main IDs 1 and 11; exchange-table row `20,200`. |
| 5 | Explicit partition `p` reads `20,200`; ordinary `WHERE id=20` returns zero; exchange table holds ID 1. |
| 6 | Exchange back restores main IDs 1 and 11; stage holds ID 20. |
| 7 | Stage is empty after DELETE. |
| 8 | Stage contains `2,20` before the next exchange. |
| 9 | Main partition `p` contains `2,20`; stage holds ID 1. |
| 10 | Main rows are `2,21` and `11,110`; stage still holds ID 1. |
| 11 | Stage is empty after DELETE of ID 1. |
| 12 | Main contains IDs 2, 3 and 11 before TRUNCATE. |
| 13, original tables | Main contains only `11,110`; original stage remains empty. |

Keep all six original predicates. Build retained states by executing the original
EXCHANGE sequence on each table pair. Do not copy misplaced rows with INSERT:
that would route them to another partition and remove the condition under test.
Keep the explicit `PARTITION(p)` query and the ordinary WHERE query as separate
predicates. A final row comparison alone does not check both access paths.

The existing SQLite predicate counts three DONE intents whose SQL contains
`EXCHANGE PARTITION ... WITHOUT VALIDATION`. Retained pairs add more matching
intents. Restrict the count to the exact original SQL:

```sql
source_sql = 'ALTER TABLE ddlcompat.t EXCHANGE PARTITION p WITH TABLE ddlcompat.stage WITHOUT VALIDATION'
```

Keep the expected count of three. Each must retain `target_sql=source_sql` and
two transitions. Keep the shared check that all DDL intents are DONE. Do not
increase the expected original count or remove the two-table transition check.

The proposal has 85 operations/transactions, in batches of 5, 4 and 76. It adds
18 retained tables. Keep replay label `partition-exchange` and its stop after
transaction 5, while the misplaced row exists. Pass final observations and the
case ID to replay. Cleanup follows saved-state/replay checks and removes only
the 18 retained tables. Keep original `t` and `stage`.

## Partition maintenance and unlogged operations

Keep all nine original operations and restarts before operations 6 and 9.
Retain prefixes 1–2 through 1–8 on seven independent tables:

| Last original operation | Required retained state |
|---:|---|
| 2 | Initial rows `1,10` and `2,20`, with RANGE/HASH subpartitions. |
| 3 | Same rows and schema after REBUILD PARTITION ALL. |
| 4 | Same rows and schema after ANALYZE PARTITION psp0. |
| 5 | Same rows and schema after OPTIMIZE PARTITION p. |
| 6 | Same rows and schema after REPAIR PARTITION ALL. |
| 7 | Same rows/schema after CHECK PARTITION ALL EXTENDED; no source transaction. |
| 8 | Same rows/schema after ANALYZE PARTITION LOCAL ALL; no source transaction. |
| 9, original `t` | Exact updated rows `1,11` and `2,21`. |

Keep the existing final predicate and compare every retained table's rows and
schema. Preserve `transactions: 0` on operations 7 and 8 and their retained copies.
The proposal has 44 source operations but only 39 transactions. Five operations
are unlogged. Batch sizes are 5, 3 and 36. No offline replay path exists for this
case; do not add one for an execution optimization.

Use the source batch's per-operation boundaries to verify unlogged behavior.
For each step declared `transactions: 0`, require an empty GTID delta and equal
start/end GTID sets, files and offsets. Put this check inside the body assertion
so a failure has named evidence. Apply it to retained copies too. Keep the shared
aggregate transaction/checkpoint checks. The current helpers record boundaries
but do not validate each zero-transaction declaration in a source batch.

Add the small check to the lab phase helper, with focused unit tests. Test that
an unexpected GTID or offset change fails. Do not add waits or client calls for
these checks: all required boundaries already exist in the batch results.

## Implementation and validation order

1. Convert the three cases with the existing phase/final-observation helpers.
   Keep SQL, transaction declarations, restart positions and profile selections.
   Extend the two replay calls. Keep the original saved-schema checks and scope
   the original-exchange intent count as described above.
2. Add focused unit tests for retained table isolation, source preservation,
   all 13 old predicates, cleanup and phase/final-check name conflicts. Test
   zero-transaction boundary validation with both valid and invalid results.
   Run only the affected workflow, phase and final-observation unit tests.
3. Run the three cases once in one forward MyISAM/default/SQL fixture with
   coverage. Verify both replay stops/resumes, offsets, GTIDs, saved algorithms,
   original exchange intents, unlogged boundaries and cleanup. Inspect support
   bundles before rerunning a failed case.
4. Compare matrix/catalog selections and record client calls, setup, case,
   coverage-export and cleanup time. Use source/predicate maps rather than a
   per-case coverage claim from the saved group report. Leave other profiles,
   benchmarks, syntax tests and the full suite to CI unless a new failure needs
   another local profile.

Focused integration command for the implementation step:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-partition-key-algorithm --case ddl-compat-partition-exchange-unchecked --case ddl-compat-partition-maintenance --coverage"
```

After these cases pass, audit all 11 partition cases against the consolidation
plan. Record local completion and remaining CI validation. Then review stored
objects, character sets/collations, data types and row-key/index operations.
Do not rebalance jobs or choose the final short PR list yet.


## Implementation and focused results

The three cases now use 10 body batches and final observations. All 35 original
operations, 13 original predicates, seven restarts and both replay paths remain.
The lab phase helper validates unlogged operations from captured boundaries.
It adds no SQL client calls. Production replication code did not change.

All three cases passed on forward MyISAM/default/SQL with coverage:

| Case | Saved CI client calls | New client calls | Local case seconds | Named assertions |
|---|---:|---:|---:|---:|
| KEY algorithms | 224 | 71 | 38.41 | 46 |
| Unchecked exchange | 219 | 64 | 31.77 | 44 |
| Partition maintenance | 148 | 50 | 28.06 | 15 |

The successful case results total 185 client calls, compared with 591 in saved
CI. These are harness calls, not applier target statements. The old times came
from CI and the new times came from a local machine. They do not establish a
controlled elapsed-time speedup.

The first shared fixture passed EXCHANGE, then failed the new KEY assertion.
The assertion expected an explicit algorithm 2. Existing schema code and its
unit tests encode default algorithm 2 as an omitted field. The corrected check
requires a KEY table and interprets the omitted algorithm as 2. The support
bundle showed no active GTID or pending DDL. Only KEY and the unrun maintenance
case were rerun, in one second fixture. The passed EXCHANGE case was not repeated.
Thus these results span two fixtures. Both cleaned up; the second fixture also
passed its shared saved-schema restart.

All 105 named assertions passed across the successful cases. Full comparisons
covered ten KEY tables, 20 exchange tables and eight maintenance tables. Raw
metadata confirmed InnoDB on source/native and MyISAM on target. Read-only state
checks verified final offsets, DONE intents, explicit algorithm 1 on original
tables, default algorithm 2 on the retained table and the three original exchange
intents with both table transitions. Replay stopped after transactions three
and five, then resumed to all 38 KEY and 85 exchange operations. Both paths used
an unreachable source address. Retained-table cleanup passed.

Maintenance executed 44 operations and 39 transactions. All five unlogged
operations retained equal start/end GTID sets, files and offsets. The source
GTID deltas were empty. Body assertion evidence records five completed unlogged
validations. The final UPDATE and all retained maintenance row checks passed.

The successful KEY/maintenance fixture used 11 source phases: seven body batches,
two setup batches and two cleanup batches. Setup took 14.51s, including 11.67s
for container startup and 2.35s for database setup. Coverage export took 7.19s.
Fixture cleanup took 11.12s. Dependency build layers were reused.

That two-case fixture covered 9,319 of 20,880 mapped runtime lines. The first
fixture covered 9,302 lines and includes the failed KEY assertion path. Neither
report is per-case coverage. Do not combine them into a claim of controlled
three-case coverage parity against the saved full partition group.

All 21 focused Swift tests and 18 feature/migration tool tests passed. Formatting,
DDL catalog and matrix checks passed. The matrix keeps 183 jobs, 1,545 obligations
and 182 coverage collections, with the same groups and profile exclusions.
No other profile, full suite, syntax suite or benchmark ran.

Evidence:

- `artifacts/lab/20261103T022243Z-8e2a4af5/result.json`: EXCHANGE passed; later KEY assertion failed.
- `artifacts/lab/20261103T025717Z-e0784c02/result.json`: corrected KEY and maintenance passed.
- `artifacts/partition-administration-review/results.json`
- `artifacts/partition-administration-review/state-results.json`
- `artifacts/partition-administration-review/source-preservation.json`
- `artifacts/partition-administration-review/matrix-comparison.json`
- `artifacts/partition-administration-review/group-audit.json`
- `artifacts/partition-administration-review/unit.log`

## Partition area: local completion audit

All 11 cases now use final observations. The source audit counts 34 body batches
and 23 deliberate live restarts. Case IDs, group membership and exclusions remain.
Seven existing offline replay paths remain; the other four cases did not gain
replay paths for this optimization.

| Cases | Focused local evidence |
|---|---|
| RANGE/exchange and HASH/KEY/LIST pilot | `artifacts/lab/20261030T214824Z-a6c4714d/result.json` |
| HASH forms, subpartitions and expressions | `artifacts/lab/20261102T173725Z-62daa299/result.json` |
| Column renames, RENAME COLUMN and column bounds | `artifacts/lab/20261103T020310Z-14ac257a/result.json` |
| KEY algorithms, unchecked exchange and maintenance | The two runs listed above; only successful case results count. |

This completes the local partition conversion work in Slice 3. It does not
complete full-matrix validation or establish a new whole-group elapsed time.
The local measurements used different runs and code revisions. Keep the later
full instrumented CI run for group timing, profile validation and job balancing.
Choose the final short PR selection after that analysis.

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
remain. Next: review temporary-table workflows. Preserve session behavior,
source logging, permanent-table name resolution and filters. Keep full-matrix
validation and final balancing later.
Continue character sets/collations, data types and row-key/index operations in
the overall consolidation plan after these group reviews.
