# Stored routine ALTER and view CHECK OPTION: workflow review

## Decision

Convert `ddl-compat-stored-objects` to four body batches and final observations.
Keep its case ID, profiles and `ddl-views-routines-temporary-tables` group. Keep
all 15 original operations first, all 11 predicates, restarts before operations
4, 9 and 15, and the replay stop after transaction four.

Retain earlier states in a separate database, `stored_alter_results`. This
preserves both original database-wide absence queries and the original journal
count. Use the helpers from the views/routines pilot. No production behavior or
generic comparison change is needed.

The review used saved evidence. Implementation and focused validation are now
complete; results follow below. The preceding pilot was committed as `533acef`.

## Names and tested scope

Consult MySQL documentation before naming features. Use
[ALTER PROCEDURE](https://dev.mysql.com/doc/refman/8.4/en/alter-procedure.html),
[ALTER FUNCTION](https://dev.mysql.com/doc/refman/8.4/en/alter-function.html)
and [The View WITH CHECK OPTION Clause](https://dev.mysql.com/doc/refman/8.4/en/view-check-option.html).

Use the case title **Stored routines and views: ALTER characteristics, CHECK
OPTION and row effects**. The original statements change routine characteristics,
not routine bodies. They change view security and CHECK OPTION metadata and
then execute valid writes through the views.

The current case does not attempt writes that violate CHECK OPTION. It does not
test the difference between LOCAL and CASCADED on nested views. Preserve its
metadata and valid-write checks without claiming those extra conditions.
Do not add an error-policy test as part of this execution conversion.

The source uses existing `root@localhost` definers. Missing-definer behavior
remains in `ddl-compat-absent-definers`. Keep the default engine behavior of this
case; do not enable `nativeInnoDB` for the MyISAM profile.

## Saved measurements and evidence

Successful CI run `40454033524`, commit `efb3458`, has a complete report with no
failed shards, missing shards or missing coverage. The case definition still
matches that commit. All four default/profile executions passed.

| Profile | Case seconds | Harness SQL client calls |
|---|---:|---:|
| 8.4 → 5.7 MyISAM | 52.45 | 263 |
| 5.7 → 8.4 InnoDB | 51.93 | 262 |
| 5.7 → 5.7 InnoDB | 50.32 | 262 |
| 5.7 → 5.7 MyISAM | 49.65 | 262 |

These are harness calls, not applier target statements. Coverage belongs to the
larger stored-object/temporary-table group. It cannot establish per-case line
coverage or prove this case redundant. The pilot cases do not cover its ALTER
characteristics, CHECK OPTION metadata or multi-view DROP journal assertion.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/stored-object-alter-review/baseline.json`: four saved results.
- `artifacts/stored-object-alter-review/source-review.json`: original SQL,
  predicates, retained object map, phase sizes and replay stop.
- `artifacts/stored-object-alter-review/review.py`: reproducible source audit.

## Retained object map

Keep the original sequence through operation 15, including the two routine DROP
statements, multi-view DROP and final DELETE. Next create `stored_alter_results`
with CHARACTER SET utf8mb4 COLLATE utf8mb4_bin. Append the prefixes below.

Each prefix owns a table, procedure and function. Prefix 7 also owns view `v`;
prefixes 8–11 own both `v` and `v2`. Use names such as `sa_local_t`, `sa_local_p`,
`sa_local_f` and `sa_local_v`. Replace only qualified database/object references
in all statements and bodies. Do not change parameters, columns or quoted
comments. No retained prefix may reference another prefix's table or routine.

| Original prefix | Suggested name stem | Required observation |
|---|---|---|
| 1–3 | `sa_original` | Original DEFINER routine security, original procedure comment and empty base table before CALL. |
| 1–4 | `sa_procedure` | Original ALTER PROCEDURE predicate: root definer, INVOKER, MODIFIES SQL DATA and updated procedure comment. |
| 1–5 | `sa_function` | Original ALTER FUNCTION predicate: root definer, INVOKER, READS SQL DATA, deterministic YES and updated function comment. Function input 7 returns 8. |
| 1–6 | `sa_called` | Original CALL result: base row `1,11`. |
| 1–7 | `sa_local` | Original view metadata: root definer, INVOKER, LOCAL and updatable YES. View returns the CALL row. |
| 1–8 | `sa_second_view` | Both views remain defined; the second view reads base row `1,11`. |
| 1–9 | `sa_inserted` | Original INSERT-through-view result: base rows `1,11` and `2,20`. |
| 1–10 | `sa_cascaded` | Original ALTER VIEW predicate: root definer, DEFINER, CASCADED and updatable YES. Base rows remain unchanged. |
| 1–11 | `sa_updated` | Original UPDATE-through-view result through `v2`: rows `1,11` and `2,21`. |
| Original final objects | No extra prefix | Zero views and routines in `ddlcompat`; final DELETE leaves row `2,21`. |

The proposal adds nine base tables, 18 routines and nine views. It executes
79 source operations: 15 original, one CREATE DATABASE and 63 retained operations.
Body batch sizes are 3, 5, 6 and 65. Restart boundaries remain on the original
operations. Batching must not merge source transactions.

Do not copy prefixes after DROP solely to repeat absence states. The original
final absence checks already cover those states. The original table also keeps
the final DELETE result. Retained prefix 11 preserves the rows before DELETE.

## Final observations and journal checks

Map all 11 original predicates to the retained objects that hold their earlier
state. Keep the two original global absence queries unchanged:

- VIEWS count for `TABLE_SCHEMA='ddlcompat'` remains zero.
- ROUTINES count for `ROUTINE_SCHEMA='ddlcompat'` remains zero.

Keep the final DELETE query on original `ddlcompat.t`. Run explicit view and
routine metadata queries. The generic comparison checks base tables and rows,
not complete routine bodies or view query behavior. Final function calls are
read-only; do not CALL retained procedures or perform view writes during final
observations. Their source operations already exercise those writes.

Keep the SQLite journal predicate unchanged, with expected count three. It
selects original ALTER PROCEDURE `ddlcompat.p`, ALTER FUNCTION `ddlcompat.f`
and the original multi-view DROP. Each must be DONE with `source_sql=target_sql`.
Retained DDL uses a different database and must not match those source prefixes.
Do not relax the equality check, increase the original count or replace it with
an aggregate count over all retained statements. Keep the shared all-intents-DONE
check as well.

Final observations compare `ddlcompat` and `stored_alter_results`. Cleanup drops
only `stored_alter_results`, after state and replay checks. Keep original table
`t`. Final cleanup must not remove original `ddlcompat` or its final DELETE result.

## Replay and scope

Extend the existing `stored-objects` replay call with `finalObservations` and
the case ID. Keep the stop after transaction four, the original ALTER PROCEDURE.
The extra database CREATE follows all original operations, so the stop still
selects the same SQL. Resume must reach the full new source boundary and repeat
all final predicates and schema/row comparisons. Keep the unreachable source
address, GTID/offset checks and saved-schema restart.

No new negative checks, live restarts or replay paths belong in this slice.
View rename chains, conditional routines, absent definers, executable comments
and temporary tables remain in their own cases.

## Implementation and validation order

1. Convert this one case with the existing phase/final-observation helpers.
   Preserve source order, three restarts, transaction declarations and original
   DROP SQL. Extend the existing replay call. Keep the journal predicate exact.
2. Add focused unit tests for all 11 old predicates, retained reference isolation,
   body/literal preservation, phase sizes, unchanged original absence queries,
   distinct assertion names and cleanup scope. Run affected workflow, phase and
   final-observation tests only.
3. Run only this case once on forward MyISAM/default/SQL with coverage. Verify
   final metadata and values, the original three journal records, replay stop
   four/resume, final offsets and GTIDs, retained database cleanup and shared
   saved-schema restart. Inspect the support bundle before a failed-case rerun.
4. Compare matrix/catalog selection and record client calls, setup, case,
   coverage-export and cleanup time. Keep other profiles, completed pilot cases,
   syntax tests, benchmarks and full-suite validation for CI unless new evidence
   requires another local profile.

Focused integration command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-stored-objects --coverage"
```

After this case passes, review view rename chains. Preserve error 1450 checks,
view-transition journal records and row-schema-cache exclusions. Continue with
conditional routines and absent definers after that. Keep final group balancing
and PR test selection until the later full instrumented CI comparison.


## Implementation and focused results

The case now lives in `StoredObjectAlterWorkflowCases.swift`. It uses four body
batches and final observations over two databases. All 15 original operations
remain first, including the three original restart points. All 11 original
predicates and the original journal query remain. Retained histories add nine
base tables, 18 routines and nine views in `stored_alter_results`. Production
replication code did not change.

The case passed on forward MyISAM/default/SQL with coverage:

| Saved CI client calls | New client calls | Local case seconds | Named assertions |
|---:|---:|---:|---:|
| 263 | 86 | 39.37 | 52 |

These are harness calls, not applier target statements. The old timing came
from CI and the new timing came from a local machine. They do not establish a
controlled elapsed-time speedup.

All 52 named assertions passed. They include 20 explicit final queries, their
20 replay repetitions, four full schema/row comparisons, four body batches,
three live restarts and cleanup. Routine definer/security/data-access/comment
metadata matched. Both LOCAL and CASCADED view metadata and all valid row
operations matched. The original absence queries returned zero. Final DELETE
left row `2,21`. Final observations did not write data or call procedures.

Read-only SQLite checks confirmed the unchanged count of three original DONE
journal records, each with `source_sql=target_sql`. All other DDL intents were
DONE. The final file offset and applied group matched all 79 source operations.
Replay stopped after the original ALTER PROCEDURE at transaction four, then
resumed to transaction 79 with the exact GTID set and file offset. It used an
unreachable source address. Saved-schema restart and cleanup passed.

Full comparisons included the original base table and all nine retained base
tables. Raw metadata confirmed InnoDB on source and MyISAM on native/target.
Saved schemas in the retained database numbered nine, with views/routines
excluded from that row-schema cache count. Cleanup dropped only the retained
database, after journal and replay checks.

The fixture used six source phases: four body batches, one setup batch and one
cleanup batch. Setup took 14.76s, including 11.90s for container startup and
2.27s for database setup. Coverage export took 5.51s. Fixture cleanup took 11.07s.
Combined runtime coverage was 8,178 of 20,880 mapped lines. Saved CI coverage
covers the larger group, so it cannot establish per-case parity here. Source
and predicate audits preserve the original conditions.

All 16 focused Swift tests and 18 feature/migration tool tests passed. Formatting,
DDL catalog and matrix checks passed. The matrix keeps 183 jobs, 1,545 obligations
and 182 coverage collections, with the same groups and exclusions. No completed
pilot case, other profile, full suite, syntax suite or benchmark was rerun.
The test guide now describes this case's batches and replay stop.

Evidence:

- `artifacts/lab/20261103T034911Z-7e124c39/result.json`
- `artifacts/stored-object-alter-review/results.json`
- `artifacts/stored-object-alter-review/state-results.json`
- `artifacts/stored-object-alter-review/source-preservation.json`
- `artifacts/stored-object-alter-review/matrix-comparison.json`
- `artifacts/stored-object-alter-review/unit.log`

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
Next: review full `charset-conversion` states and assertions, then DEFAULT session
context and encoded SQL. Keep DML inventories, full-matrix validation and final
balancing later.
