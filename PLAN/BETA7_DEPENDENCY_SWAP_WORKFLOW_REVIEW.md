# Review of generated-column dependencies and column-name swaps

## Decision

The basic generated-column and expression batches are committed as `9815710`.
Convert these two remaining cases to source batches and final observations:

- `ddl-compat-generated-dependencies`
- `ddl-compat-column-swaps`

Keep their IDs, profile selections and existing CI group. Keep the current four
live restarts in each case. Keep replay stopped after transaction four for
dependencies and transaction three for swaps. Both cases remain separate named
results in one shared fixture. Leave `foreignKeyColumnSwaps` unchanged.

The review used saved results and source inspection. The implementation now
uses the retained-table layout below. Focused validation results follow at the
end of this document.

## Names

Use **ALTER TABLE: generated-column dependencies and conversions** and
**ALTER TABLE: swap column names and preserve key references** as the titles.
MySQL describes column renaming, redefinition and reordering separately. Its
manual also describes swaps and cycles of column names. Keep the existing CHANGE
SQL; do not replace it with the manual's RENAME COLUMN examples.
[ALTER TABLE](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html).

The dependency case changes expressions and converts between stored generated
columns and ordinary columns. Use the terminology from
[ALTER TABLE and Generated Columns](https://dev.mysql.com/doc/refman/8.4/en/alter-table-generated-columns.html).
The source tests and native results define which combinations this case checks;
the names do not claim all conversions or rename combinations are tested.

## Baselines and limits of the measurements

Full CI run `40454033524`, commit `efb3458`, passed. Its summary and report are
complete, with no failed shards or missing coverage. Each cell below is
**case seconds / harness SQL client calls**, for the default SQL selection.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| Generated dependencies | 80.14 / 365 | 69.84 / 364 | 81.26 / 364 | 80.95 / 364 |
| Column swaps | 57.54 / 262 | 50.60 / 261 | 57.96 / 261 | 57.81 / 261 |

Later local phase conversions also passed on forward MyISAM:

| Case | Current phases | Current live restarts | Local seconds | Client calls |
|---|---:|---:|---:|---:|
| Generated dependencies | 18 | 4 | 85.62 | 273 |
| Column swaps | 13 | 4 | 77.50 | 215 |

Use those 273 and 215 calls as the later execution baseline. Their reduction
from 365 and 262 already occurred. Do not attribute it to the next change.
The dependency phase conversion also removed two ordinary-write restarts, as
recorded in the earlier review. Preserve the current four; remove no more.
All SQL and explicit expected literals remain unchanged from the CI baseline.
Column swaps also retain the same restart flags.

Evidence:

- `artifacts/dependency-swap-workflow-review/baseline.json`: CI costs by case,
  profile and role.
- `artifacts/dependency-swap-workflow-review/source-comparison.json`: unchanged
  SQL/expected literals, phase counts and the prior restart change.
- `artifacts/generated-phase-review/results.json`: later dependency run.
- `artifacts/generated-rename-phase-review/results.json`: later swap run.
- [Earlier dependency review](BETA7_TABLE_COLUMN_INDEX_REVIEW.md): why the two
  ordinary-write restarts were removed.

CI coverage is for the whole table/column/index group. The later dependency
run isolates that case, but the later swap run also includes generated
expressions. A new combined selection will differ from both. Do not use these
sets to claim per-case coverage parity or to remove an assertion. Keep SQL-call,
source-operation and elapsed-time counts separate. Hosts differ too.

## Execution method and cost tradeoff

Keep each original sequence first, including its final DROP. Append independent
tables that repeat the necessary operations up to each state to be checked.
These retained tables make the state available for one final comparison. Do not
use CREATE LIKE or INSERT SELECT to copy a final result instead of executing its
ALTER history: that would omit the operation under test on the retained table.

Each case can use five body batches around its four current restarts. Run one
final observation batch per server and one complete schema/row comparison after
the last body batch. Replay must run those observations again. Remove retained
tables only after replay and saved-state checks.

This adds source DDL and rows. The reviewed dependency layout has 17 retained
tables and 114 total source operations. The swap layout has 12 retained tables
and 78 operations. Those counts replace 31 intermediate comparison phases with
ten body batches across both cases. They do not reduce the workload to ten
transactions: preserve every original transaction boundary.

Measure the extra source work and total case time. Do not assume fewer client
calls must be faster. If a large final batch exceeds a timeout, inspect its
measured operation and failure first. Do not raise timeouts or split it into
additional CI jobs without evidence.

## Generated-column dependencies

The current case has 23 operations. The original table sequences are:

- `t`: operations 1–12, including dependent `g`/`h` expressions and conversions.
- `q`: operations 13–18, including DROP, ADD and another DROP of `g`.
- `l`: operations 19–22, including the literal string containing backticks.
- Operation 23: DROP all three original tables.

The following prefixes use positions within their own table sequence. For
example, prefix 4 of `q` means original operations 13–16. Substitute only the
qualified table name. Keep literal strings and expression identifiers unchanged.

| Original table / prefix | Suggested retained table | State and required observation |
|---|---|---|
| `t` / 2 | `gd_seed` | `a=5,g=6,h=12`, original definitions, index and literal value. |
| `t` / 3 | `gd_replaced` | Rename the base column before replacing the expression: `b=5,g=7,h=14` and the unchanged backtick literal. Keep the original explicit query. |
| `t` / 4 | `gd_replaced_write` | UPDATE after restart: `g=8,h=16`; base value 6. |
| `t` / 5 | `gd_reverse_order` | Expression replacement before the base-column rename: `c=6,g=9,h=18`. Keep clause order. |
| `t` / 6 | `gd_renamed` | Rename `g` to `new_g`, change the virtual expression to `new_g*3`, and retain `new_g=9,h=27` before the next UPDATE. |
| `t` / 7 | `gd_renamed_write` | UPDATE after restart: `new_g=10,h=30`. |
| `t` / 8 | `gd_dropped` | Drop dependent `h`, rename the input, change its expression: `d=7,new_g=11`; `h` is absent. |
| `t` / 9 | `gd_ordinary` | Convert `new_g` to an ordinary column. Its value remains 11; metadata no longer marks it as generated. |
| `t` / 11 | `gd_generated` | Directly UPDATE ordinary `new_g` to 12, then convert `d` to STORED `id+3`: `d=4,new_g=12`. |
| `t` / 12 | `gd_final` | Change the primary key after restart: `id=2,d=5,new_g=12`. |
| `q` / 2 | `gd_q_seed` | Initial `a=8,g=9` and stored definition. |
| `q` / 3 | `gd_q_dropped` | Rename input and DROP `g`: `id=1,b=8`; `g` is absent. |
| `q` / 4 | `gd_q_recreated` | Recreate `g AS(b*2)`: `g=16`. Preserve this state before the following DROP. |
| `q` / 6 | `gd_q_final` | DROP `g`, rename input, then UPDATE: `id=1,c=9`; no generated `g`. |
| `l` / 2 | `gd_literal_seed` | Original column `a` and generated string containing the exact bytes for backtick-a-backtick. |
| `l` / 3 | `gd_literal_renamed` | Rename column `a` to `b`, but keep the string literal unchanged. Preserve the explicit `b,g` query. |
| `l` / 4 | `gd_literal_empty` | DELETE leaves an empty table with the renamed definition. |

The `t` prefixes add 67 operations, `q` adds 15, and `l` adds nine. Combined with
the original 23, the case has 114 operations. Add an explicit final metadata
check that original tables `t`, `q` and `l` are absent. Keep all ten existing
explicit query predicates, with only the retained table name changed. Compare
all columns, expression definitions, storage forms and `by_g` references too.

Keep restarts before original operations 4, 7, 10 and 12. The five body batches
have 3, 3, 3, 2 and 103 operations. Do not add restarts inside retained prefixes.

The original replay stop is after operation 4, the UPDATE of `b` to 6. Keep it.
Unlike the swap path, this case's call currently omits `finalObservations`.
Pass `test.finalObservations` to that existing `replayDDLWorkflow` call. The
helper already resets the retained tables and writes `replay-` assertion files.
Without this parameter, replay would compare only its final database state and
omit the named retained-state predicates. Do not add a separate replay runner.

## Column-name swaps and key references

Keep all 15 original operations first:

- `t`: operations 1–10. They swap names, reorder columns, rename three columns,
  add a defaulted column, reuse a dropped name and delete a row.
- `g`: operations 11–14. They swap a generated expression's input and another
  column, then update the renamed input.
- Operation 15: DROP both original tables.

Retain prefixes 2 through 10 of `t`, and prefixes 2, 3 and 4 of the local `g`
sequence. This adds 54 + 9 operations, for 78 total. Use descriptive table names
such as `cs_seed`, `cs_swapped`, `cs_written`, `cs_positioned`, `cs_chain`,
`cs_added`, `cs_added_write`, `cs_reused`, `cs_deleted`, `cs_g_seed`,
`cs_g_swapped` and `cs_g_updated`.

| Local prefix | Required final observation |
|---|---|
| `t` / 2 | Original two rows, physical column order and primary/secondary keys. |
| `t` / 3 | Keep `SELECT * ORDER BY b` and its existing result. Keep explicit key mapping `PRIMARY(b,a)`, `ka(b)`, `kb(a)`. |
| `t` / 4 | UPDATE through the renamed key: `b=1,a=11,c=101`; the second row remains unchanged. |
| `t` / 5 | FIRST/AFTER reorder: keep the original `SELECT * ORDER BY a`. Physical column order is part of the result. |
| `t` / 6 | Three-column rename: keep the original `SELECT * ORDER BY b`. Compare the renamed key references. |
| `t` / 7 | ADD with DEFAULT plus swap: keep both rows and the expected default 7 in the required position. |
| `t` / 8 | UPDATE through the new names: keep both rows from the existing `b,n,d,c` predicate. |
| `t` / 9 | DROP `kb` and its old column, then reuse the name: keep both rows from `SELECT * ORDER BY c`. Verify `kb` is absent and the remaining keys reference the correct columns. |
| `t` / 10 | DELETE the second row: retain the original one-row `SELECT *` result. |
| `g` / 2 | Original input values `a=10,b=20,g=11`. |
| `g` / 3 | Swap inputs and replace the expression in one ALTER: `id=1,b=10,a=20,g=11`. |
| `g` / 4 | UPDATE after the swap: `id=1,b=12,a=20,g=13`. |

Keep all eleven existing explicit query predicates and expected values. Do not
replace `SELECT *` with a projection that hides physical column order. The
complete comparison must retain `ORDINAL_POSITION`, index-part order, uniqueness,
generation expressions and both rows before DELETE. Add an explicit final check
that original tables `t` and `g` are absent.

Keep restarts before original operations 4, 6, 8 and 13. The five body batches
have 3, 2, 2, 5 and 66 operations. Replay still stops after transaction three,
the first name swap. Its existing call already passes `finalObservations`.
Do not change the adjacent InnoDB foreign-key swap case or its replay behavior.

## Implementation and local validation

1. Implement both case definitions and the dependency replay argument. Keep the
   original SQL first. Use explicit retained sequences and named observations.
   Keep the shared final schema/row comparison and delayed cleanup.
2. Replace the old phase-count expectations in focused unit tests. Check each
   retained prefix, local sequence range and qualified-name substitution. Check
   the eight live restarts, both replay boundaries, original DROP statements,
   literal bytes, ordinary/generated metadata, physical column order and keys.
   Keep unrelated column/index and foreign-key checks unchanged.
3. Check the DDL catalog and matrix. They must remain at 183 jobs, 1,545
   obligations and 182 coverage collections, with the same IDs and exclusions.
   Neither reviewed case owns a retired-case migration assertion.
4. Build one matching coverage image and run both cases in one forward
   MyISAM/default/SQL fixture:

   ```sh
   make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-generated-dependencies --case ddl-compat-column-swaps --coverage"
   ```

5. Verify all named live and replay results, both stop/resume sequences, eight
   live restarts, GTID/file-offset checkpoints, saved-schema restart, cleanup and
   coverage export. Check the support bundle before rerunning an applier failure.
6. Record setup, source-operation counts, SQL client calls, case duration,
   cleanup and coverage export separately. Use the earlier local phase runs as
   the current execution baseline. State the different coverage scopes.
7. Update `docs/TEST_LAB.md` to explain final retained-state comparisons and the
   combined command. Record results in this plan and update the overall plans.

One local profile is sufficient for this change. Both definitions have identical
SQL for transactional and nontransactional targets, no engine-specific expected
values, and no profile exclusions. Existing native comparisons and replay use
the forward fixture. Keep other profiles for CI unless a concrete failure or
new branch requires another local selection. Do not rerun the completed basic
generated-column or index cases, the full suite, syntax tests or benchmarks.

## Following work

After both cases pass, review column/index syntax and ALTER column keys. They
are the remaining earlier phase conversions in this group. Preserve AUTO_INCREMENT
settings, implicit key rules and their replay stops before reducing observations.


## Implementation and focused results

Both conversions are complete. The original 23 and 15 SQL operations remain
first and unchanged. Each case has five body batches and four live restarts.
The dependency replay call now receives the final observations. The adjacent
foreign-key swap case is unchanged.

The focused run passed on `mysql84-to-mysql57-myisam`, default variant, SQL
transport, with coverage enabled. Both cases used one fixture.

| Case | Prior local client calls | New client calls | Prior local seconds | New seconds | Named assertions |
|---|---:|---:|---:|---:|---:|
| Generated dependencies | 273 | 80 | 85.62 | 46.51 | 56 |
| Column-name swaps | 215 | 82 | 77.50 | 44.74 | 42 |

The combined client-call count fell from 488 to 162. These are harness SQL
client calls, not a count of executed statements. The cases now execute 114 and
78 source operations. They preserve 22 and 15 explicit final observations,
including all 21 original query predicates. Both also compare the full schema
and rows with the native replica. The 98 named assertions include 39 replay
observations: 37 explicit checks and two full schema/row comparisons.

Replay stopped after transactions four and three, then resumed to transaction
counts 114 and 78. Both stop and final GTIDs and file offsets match the recorded
source operations. Replay used an unreachable source at `127.0.0.1:1`. All eight
live restarts, saved-schema restart, cleanup and coverage export passed.

The fixture used 14 source phases: ten body batches, two setup batches and two
cleanup batches. Setup took 18.13s, including 14.88s for container startup and
2.54s for database setup. Coverage export took 10.33s. Cleanup took 11.27s.
The coverage-image build step took 232.3s and reused its dependency layers.

Combined runtime coverage was 9,408 of 20,880 mapped lines. The earlier runs
used different case selections and builds. This is not a per-case coverage
parity claim. The retained SQL, expected results and restart/replay boundaries
provide the assertion comparison. Timing is a local observation, not a fixed
performance guarantee.

All 52 focused Swift tests and 18 feature/migration tool tests passed. The DDL
catalog check passed. The matrix keeps 183 jobs, 1,545 obligations and 182
coverage collections. Execution groups and profile exclusions are unchanged.
No other profile, full suite, syntax suite or benchmark ran.

Evidence:

- `artifacts/lab/20261030T004245Z-c9e66887/result.json`
- `artifacts/dependency-swap-workflow-review/results.json`
- `artifacts/dependency-swap-workflow-review/replay-results.json`
- `artifacts/dependency-swap-workflow-review/source-preservation.json`
- `artifacts/dependency-swap-workflow-review/matrix-comparison.json`
- `artifacts/dependency-swap-workflow-review/unit.log`

Next: review column/index syntax and ALTER column keys for the same execution
method. Preserve AUTO_INCREMENT settings, implicit key rules and replay stops.

The [column-key conversions](BETA7_COLUMN_KEY_WORKFLOW_REVIEW.md#implementation-and-focused-results)
are now complete. Both cases passed in one forward MyISAM fixture, including
five live restarts, both replay stops and the original AUTO_INCREMENT context
check. Next: review the remaining cases in the table/column/index group.
