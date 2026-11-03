# View rename chains: workflow review

## Decision

Convert `ddl-compat-view-renames` to four body batches and final observations.
Keep its ID, profiles and `ddl-views-routines-temporary-tables` group. Preserve
all 13 original operations first, all 11 predicates, restarts before operations
7, 9 and 13, and replay stop after transaction seven.

Retain earlier states in `view_rename_results`. Keep the original error 1450
checks and post-replay queries on `ddlcompat`. Scope the journal count to the
four original rename statements. Do not count retained histories as original
view transitions.

The review used saved SQL, assertions and timings. Implementation and focused
validation are now complete; results follow below. The preceding stored-object
ALTER work was committed as `3ed044c`.

## Names and tested scope

Consult MySQL documentation before naming features. Use
[RENAME TABLE](https://dev.mysql.com/doc/refman/8.4/en/rename-table.html).
Use the title **RENAME TABLE: views, table/view swaps and row effects**.

The case includes a view rename, a view/view swap, a table/view swap and a final
mixed rename. A name can identify a view at one point and a base table later.
Preserve each complete multi-pair RENAME as one source operation. Do not split
the statement or replace it with CREATE/DROP: those operations would change the
conditions under test.

Keep the default engine behavior. On the forward profile, source base tables
use InnoDB and native/target base tables use MyISAM. Do not enable `nativeInnoDB`.
The test checks expected failure of a cross-database view rename. It does not
claim that all cross-database RENAME combinations fail.

## Saved measurements

Successful CI run `40454033524`, commit `efb3458`, has a complete report with no
failed shards, missing shards or missing coverage. The case definition still
matches that commit. All four default/profile executions passed.

| Profile | Case seconds | Harness SQL client calls |
|---|---:|---:|
| 8.4 → 5.7 MyISAM | 51.68 | 251 |
| 5.7 → 8.4 InnoDB | 50.68 | 250 |
| 5.7 → 5.7 InnoDB | 50.17 | 250 |
| 5.7 → 5.7 MyISAM | 46.63 | 250 |

These are harness calls, not target applier statements. Coverage belongs to the
larger views/routines/temporary-table group. It cannot establish per-case line
coverage or justify removing this case. The completed stored-object workflows
do not cover names changing between views and base tables.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/view-rename-workflow-review/baseline.json`: four saved results.
- `artifacts/view-rename-workflow-review/source-review.json`: original SQL,
  predicates, retained object identities, phase sizes and replay stop.
- `artifacts/view-rename-workflow-review/review.py`: reproducible source audit.

## Retained object map

Keep the original sequence through the DELETE at operation 13. Then create
`view_rename_results` with CHARACTER SET utf8mb4 COLLATE utf8mb4_bin. Append the
seven prefixes below. Each history uses its own names for `t`, `aux`, `v`, `v2`,
`renamed`, `tmp`, `moved` and `final_view`. Include the temporary name used inside
multi-pair RENAME even though it does not exist after the statement completes.

Replace qualified database/object references consistently, including the view
SELECT body and every source/destination in RENAME. Do not rewrite definitions
from scratch, copy only final rows, or assign names according to their current
object type. Name identity must follow the original SQL through the type swap.

| Original prefix | Suggested stem | Required observation |
|---|---|---|
| 1–6 | `vr_seed` | Two base tables and two views. INVOKER/LOCAL view `v` reads `1,10`; DEFINER view `v2` reads `1,11`. |
| 1–7 | `vr_renamed` | Original single-rename predicates: `renamed` returns `1,10`, with root definer, INVOKER and LOCAL metadata. |
| 1–8 | `vr_swapped` | Original swapped-view predicates: `renamed` returns `1,11`; `v2` returns `1,10`. Definitions and security follow the view identities. |
| 1–9 | `vr_mixed` | `aux` is now the view and returns `1,10`; `v2` is now a base table and returns `2,20`. |
| 1–10 | `vr_updated` | UPDATE of base table `v2` leaves row `2,21`. |
| 1–11 | `vr_inserted` | INSERT through view `aux` changes base `t` to rows `1,10` and `3,30`; base `v2` remains `2,21`. |
| 1–12 | `vr_final_names` | View `final_view` returns `1,10` and `3,30`, with original INVOKER/LOCAL metadata. Base table `moved` still holds `2,21` before DELETE. |
| Original final objects | No extra prefix | Original final view still reads both rows; DELETE leaves original `moved` empty. |

Each retained prefix has two base tables and two views at its final state:

| Prefix ends | Base-table suffixes | View suffixes |
|---|---|---|
| 6 | `t`, `aux` | `v`, `v2` |
| 7–8 | `t`, `aux` | `renamed`, `v2` |
| 9–11 | `t`, `v2` | `renamed`, `aux` |
| 12 | `t`, `moved` | `renamed`, `final_view` |

The proposal adds 14 base tables and 14 views. It has 77 source operations:
13 original, one CREATE DATABASE and 63 retained operations. Body batch sizes
are 6, 2, 4 and 65. Batching must not combine source transactions. The fourth
batch still starts with the original DELETE after the third live restart.

## Final observations and saved state

Map all 11 old predicates to the retained objects that preserve each earlier
result. Keep the final COUNT on original `ddlcompat.moved`, expected zero.
Add explicit retained object-type and view-security queries. The generic schema
comparison checks table types and base-table rows, but it does not replace view
result queries or complete view metadata checks.

Compare both databases. Final observations must not INSERT, UPDATE or DELETE.
The source histories already perform those operations through the correct view
or base-table identity. Cleanup drops only `view_rename_results` after state and
replay checks. Keep original `ddlcompat` and its final objects.

The current journal predicate counts all DONE intents with nonempty
`context_json.viewTransitions`, expected four. Retained histories add more
matching intents. Add a source-SQL restriction selecting exactly original
operations 7, 8, 9 and 12. Keep the original expected count of four and the
nonempty transition requirement. Keep all original SQL strings unchanged.
Do not increase the count to include retained histories or remove the context
metadata check. Keep the shared all-intents-DONE check.

Preserve the original current-schema exclusion for `ddlcompat.final_view` and
`ddlcompat.renamed`. Extend the state audit to the retained objects: all 14
current base-table identities must be present, and all 14 current view identities
must be absent from the row-schema cache. Use the type map above. Do not treat
every name ending in `v2` as a view: it identifies a base table after operation 9.

## Expected failure and replay

Keep the original rejected SQL unchanged:

```sql
RENAME TABLE ddlcompat.final_view TO mysql.moved_view
```

Run the existing check on source, native and target after the live positive
workflow. Each must return error 1450. Keep the before/after GTID, file and offset
checks. Preserve `view-rename-rejections.json`. Keep this expected failure outside
ordinary final success queries. Retained objects must not change the check's
original names or destination.

Extend the `view-renames` replay call with final observations and the case ID.
Keep its stop after transaction seven, the original single-view rename. Extra
histories follow all 13 original operations, so the stop selects the same change.
Resume must reach the full new source boundary and repeat retained observations.
Keep the unreachable source address and verify exact final GTIDs and offsets.

After replay, retain the existing target/native metadata comparison over views
in `ddlcompat` and the original `final_view` row check. The retained database
keeps these queries' scope unchanged. Cleanup follows these checks. Preserve
the shared saved-schema restart.

## Implementation and local validation

1. Convert this case with the existing phase/final-observation helpers. Keep
   original SQL first, restart points, source transaction declarations and the
   expected cross-database error path. Extend the replay call and scope the
   original journal count as described above.
2. Add focused unit tests for all 11 old predicates, qualified reference mapping,
   all multi-pair rename chains, object-type identities and the temporary alias.
   Test distinct assertion names, cleanup scope and original journal selection.
   Run affected workflow, phase and final-observation tests only.
3. Run only this case once on forward MyISAM/default/SQL with coverage. Verify
   the four original view-transition records, cache identities, error 1450 on
   all three roles with unchanged binlogs, replay stop seven/resume, final GTIDs
   and offsets, metadata/results, saved-schema restart and cleanup. Inspect the
   support bundle before rerunning a failed case.
4. Compare matrix/catalog selection. Record calls and setup, case, coverage-export
   and cleanup time. Keep completed stored-object cases, other profiles, syntax
   tests, benchmarks and full-suite validation for CI unless new evidence needs
   another local profile. Do not claim per-case coverage parity against the
   saved full-group report.

Focused integration command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-view-renames --coverage"
```

After this case passes, review conditional routines, then absent definers.
Keep full-matrix validation, final group balancing and short PR selection for
later, as required by the overall consolidation plan.


## Implementation and focused results

The case now lives in `ViewRenameWorkflowCases.swift`. It uses four body batches
and final observations over two databases. All 13 original operations remain
first, including each complete multi-pair rename statement. All 11 original
predicates, three live restarts and replay stop seven remain. Production
replication code did not change.

The case passed on forward MyISAM/default/SQL with coverage:

| Saved CI client calls | New client calls | Local case seconds | Named assertions |
|---:|---:|---:|---:|
| 251 | 97 | 40.46 | 50 |

These are harness calls, not target applier statements. The old timing came
from CI and the new timing came from a local machine. They do not establish a
controlled elapsed-time speedup.

All 50 named assertions passed. They include 19 explicit final queries and their
19 replay repetitions, four full schema/row comparisons, four body batches,
three live restarts and cleanup. Object-type queries confirmed view/view and
table/view identities. Original and computed view rows, definer/security/check
metadata and base-row effects matched source/native/target.

Read-only state checks confirmed four original DONE view-transition records,
all DDL intents DONE and exactly 14 retained current base-table schemas. None
of the 14 retained views entered the row-schema cache. Original view-cache
exclusions remained. Error 1450 occurred on source, native and target, with
unchanged GTIDs, files and offsets. `view-rename-rejections.json` records all
three errors. Existing post-replay original view metadata and row checks passed.

Replay stopped after the original single-view rename at transaction seven. It
resumed to all 77 source operations with the exact GTID set and file offset.
It used an unreachable source address. The original database retained its final
objects. Retained-database cleanup and shared saved-schema restart passed.
Raw metadata confirmed InnoDB on source base tables and MyISAM on native/target,
across two original base tables and 14 retained base tables.

The first local attempt failed a SQLite query in the new journal check. It used
the MySQL literal formatter, which emits CONVERT syntax. The helper now quotes
SQLite strings directly and escapes single quotes. Unit guards cover this SQL
dialect and quoted names. The failed run's support bundle showed no active GTID
or pending DDL. Corrected queries also returned the expected counts 4/0/14 on
the read-only bundle. Only this case was rerun. The failed run remains under
`artifacts/lab/20261103T040813Z-94114af3`.

The successful fixture used six source phases: four body batches, one setup
batch and one cleanup batch. Setup took 14.26s, including 11.54s for container
startup and 2.35s for database setup. Coverage export took 6.19s. Fixture cleanup
took 11.38s. Combined runtime coverage was 8,293 of 20,880 mapped lines. Saved CI
coverage covers the larger group and cannot establish per-case parity here.
The source and predicate audits preserve the original conditions.

All 18 focused Swift tests and 18 feature/migration tool tests passed. Formatting,
DDL catalog and matrix checks passed. The matrix retains 183 jobs, 1,545 obligations
and 182 coverage collections, with the same groups and exclusions. No completed
stored-object case, other profile, full suite, syntax suite or benchmark was
rerun. The test guide now explains the source batches, identity checks and replay.

Evidence:

- `artifacts/lab/20261103T044052Z-ca66af72/result.json`
- `artifacts/view-rename-workflow-review/results.json`
- `artifacts/view-rename-workflow-review/state-results.json`
- `artifacts/view-rename-workflow-review/source-preservation.json`
- `artifacts/view-rename-workflow-review/matrix-comparison.json`
- `artifacts/view-rename-workflow-review/unit.log`

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
finds all 11 cases converted with the same profile selections. Next: review
character sets and collations. Keep full-matrix validation and final balancing
later.
