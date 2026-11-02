# Partition forms, subpartitions and computed bounds: workflow review

## Decision

Convert these three cases to source batches and final observations. Keep their
case IDs, Partitions feature owner, profiles and `ddl-partition-management` group.
Run them in one fixture. Keep separate named case results.

| Case suffix after `ddl-compat-` | Suggested title | Original operations | Body batches | Live restarts | Offline replay stop |
|---|---|---:|---:|---:|---|
| `partition-hash-forms` | HASH and KEY partitioning: named partitions and implicit columns | 7 | 3 | 2 | None today; do not add one |
| `subpartitions` | Subpartitioning: TRUNCATE, EXCHANGE, REORGANIZE and CREATE LIKE | 18 | 4 | 3 | Transaction 3, after TRUNCATE |
| `partition-expressions` | Partitioning expressions: evaluated bounds and RANGE COLUMNS | 13 | 4 | 3 | Transaction 3, after REORGANIZE |

Keep all 38 original operations first in each case's sequence. Keep all eight
live restarts and all 15 explicit query predicates. Append independent table
sequences that retain states which later statements change. Compare them at the
end. Batching source SQL must not combine source transactions.

The review used saved evidence without a build or integration run. Implementation
and focused validation are now complete; see the results below. The preceding
completed workflows were committed as `bf2314d`.

## Names and scope

Consult the MySQL manual before changing feature names. Use
[KEY Partitioning](https://dev.mysql.com/doc/refman/8.4/en/partitioning-key.html),
[Subpartitioning](https://dev.mysql.com/doc/refman/8.4/en/partitioning-subpartitions.html)
and [Partitioning Limitations Relating to Functions](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-functions.html).

`KEY()` selects an implicit partitioning key. Do not replace it with `KEY(id)`
for convenience: that would remove the syntax under test. A blank reported
partition expression can be valid for `KEY()`. Compare it with the native server.
The subpartition case uses both HASH and LINEAR KEY subpartitioning. The expression
case tests specific functions and constant expressions, not arbitrary SQL functions.

Keep `nativeInnoDB: true` on all three cases. Preserve the transactional-target
CREATE SQL in the HASH/KEY case. It includes repeated quoted and unquoted InnoDB
engine options. The MyISAM-target SQL omits those explicit engine options.

## Saved measurements

The review used successful CI run `40454033524`, commit `efb3458`. Its report is
complete, with no failed shards, missing shards or missing coverage. Both source
files still match that commit exactly. All 12 selected default/profile results
passed. Each cell below is **case seconds / harness SQL client calls**.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| HASH/KEY forms | 30.62 / 127 | 30.82 / 126 | 31.22 / 126 | 25.94 / 126 |
| Subpartitions | 54.50 / 287 | 55.50 / 286 | 56.14 / 286 | 43.86 / 286 |
| Expressions and bounds | 49.13 / 224 | 48.45 / 223 | 48.94 / 223 | 39.92 / 223 |

These are client calls, not SQL statement counts or applier target calls. Each
case currently uses the per-statement runner. It waits and compares database
schemas and rows after each operation. The proposed conversion replaces those
38 observation points with 11 body batches and three final observation sets.
The eight intentional restarts remain.

The saved coverage belongs to the whole partition group. It cannot show which
of these cases supplied an individual line. No evidence supports removing a case
as redundant. Their assertions differ: named/implicit partition definitions,
subpartition mutations, and evaluated numeric/date/tuple bounds.

Local evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/partition-forms-workflow-review/baseline.json`: 12 saved results.
- `artifacts/partition-forms-workflow-review/source-review.json`: exact source SQL,
  transactional alternatives, predicates, restart positions and proposed sequences.
- `artifacts/partition-forms-workflow-review/review.py`: reproducible source audit.

## HASH and KEY forms

Keep the original seven operations. Restarts stay before operations 4 and 7.
Retain prefixes 1–2 through 1–6 on five independent tables:

| Last original operation | Suggested table | Required result |
|---:|---|---|
| 2 | `pf_seed` | Two seed rows; named LINEAR HASH partitions `early,late`. |
| 3 | `pf_added` | Names `early,late,p2,p3`; unchanged rows after ADD by count. |
| 4 | `pf_coalesced` | Two remaining partitions after COALESCE; unchanged rows. |
| 5 | `pf_implicit_key` | KEY with implicit columns and two partitions; unchanged rows. |
| 6 | `pf_extra` | Named `extra` partition after ADD; unchanged rows. |
| 7, original `t` | No extra table | Exact updated values `1,11` and `2,21`. |

The first explicit predicate moves to `pf_added`. The final row predicate stays
on `t`. Preserve both original SQL alternatives in every retained CREATE.
Compare all rows and partition definitions against source and native. The shared
comparison does not select PARTITION_COMMENT. Preserve repeated COMMENT clauses
in SQL, but do not claim that existing checks verify comment precedence.

This proposal has 27 operations in body batches of 3, 3 and 21 operations.
Remove only the five retained tables during final cleanup.

## Subpartitions

Keep all 18 original operations. Restarts stay before operations 4, 8 and 18.
Preserve the original `t`, `stage` and `copy` names for SQLite checks and replay.

Use a conservative state map first: retain prefixes 1–2 through 1–17. Each prefix
must use its own table set. Rename `stage` from operation 4 and `copy` from
operation 14 in the same prefix. Never exchange with another prefix's table.
Use descriptive table names, such as `sp_truncated` or `sp_exchanged_stage`.

| Last operation | State that must remain observable |
|---:|---|
| 2 | Initial RANGE/HASH rows and two subpartitions per partition. |
| 3 | TRUNCATE `p0sp1`: IDs `2,11,12`; the truncated subpartition is empty. |
| 4–5 | Empty exchange table, then exchange input row `4,40`. |
| 6 | Validated EXCHANGE: main IDs `4,11,12`; exchange-table ID `2`. |
| 7 | REORGANIZE creates named subpartitions `a,b,c,d` and keeps the rows. |
| 8 | Row `18,180` after the second live restart. |
| 9 | DROP `p10`: main IDs `4,18`; the dropped partition is absent. |
| 10–11 | New `p2` is empty, then holds IDs `22,23`. |
| 12–13 | UPDATE sets `n=220` for ID 22; DELETE then removes ID 23. |
| 14–15 | CREATE LIKE makes an empty partitioned copy; INSERT SELECT fills it. |
| 16 | Copy retains its rows after REMOVE PARTITIONING. |
| 17 | Main table uses LIST COLUMNS with LINEAR KEY ALGORITHM=2 subpartitions. |
| 18, original tables | Final main row 22 has `n=221`; copy still has `n=220`; stage still has ID 2. |

Keep all seven original predicates. The final names must remain exactly
`p4sp0,p4sp1,p18sp0,p18sp1,p22sp0,p22sp1`.

The shared schema comparison reads partition names, methods, expressions and
bounds. It does not read subpartition names, methods or expressions. Its repeated
partition rows alone cannot verify those fields. Add case-local final queries
for named subpartitions after REORGANIZE and for the initial/final subpartition
methods and counts. Keep the existing final-name predicate and SQLite check for
two saved subpartitions under the first partition of the original `t`.

This conservative proposal has 170 operations, with batches of 3, 4, 10 and 153.
It adds 34 retained tables to the three original tables. This increases source
work to avoid repeated client waits and comparisons. Measure its cost. Do not
assume it is faster from call counts alone. A later reduction must map each
removed state to an equivalent retained row/schema assertion.

Pass `finalObservations` and `observationCaseID` into the existing subpartition
replay call. Keep its stop after transaction 3 and its resume checks. Replay must
repeat the final predicates and compare the retained tables. Cleanup must follow
saved-state and replay checks, and remove only retained tables.

## Partitioning expressions and evaluated bounds

Keep all 13 original operations. Restarts stay before operations 4, 10 and 13.
Do not replace source expressions with precomputed constants.

| Original sequence | Suggested retained table | Required result |
|---|---|---|
| 1–2 | `pe_dates` | Three date rows before REORGANIZE; original evaluated bound and MAXVALUE. |
| 1–3 | `pe_reorganized` | Bounds exactly `739982,740347,MAXVALUE`; rows in their expected partitions. |
| 1–4 | `pe_truncated` | IDs `2,3` after TRUNCATE; the old partition is empty. |
| 1–5 | `pe_updated` | Updated value 21 while the table still uses RANGE/TO_DAYS. |
| 7–8 | `pe_list_seed` | LIST values from ABS, addition and DIV; partition `p` contains `1,2,3`. |
| 7–9 | `pe_list_added` | Computed value 5 in the new partition definition; partition still empty. |
| 7–10 | `pe_list_filled` | Row `5,50` in the new partition, before DELETE of ID 2. |
| Original final tables | No extra tables | HASH/EXTRACT on `t`; final rows of `l`; tuple routing on `c`. |

The LIST sequences start at operation 7. Do not copy unrelated date-table or
RANGE COLUMNS operations into them. The original `c` table remains available for
both tuple predicates: ID 9 in partition `p`, ID 10 in partition `q`.

Preserve all six original predicates. Keep the SQLite history check for bound
`739982` on original table `t`, even though its final partition method is HASH.
Pass the final observations and case ID into the existing replay call. Keep the
stop after transaction 3 and run the final predicates again after resume.

This proposal has 36 operations, in batches of 3, 6, 3 and 24. It adds seven
retained tables. Cleanup must keep original tables `t`, `l` and `c`.

## Implementation and validation order

1. Convert all three case definitions using the existing phase/final-observation
   helpers. Keep profile SQL alternatives, source order, transaction counts and
   restart boundaries. Extend the two existing replay calls.
2. Add focused lab unit tests for source preservation, phase sizes, both SQL
   alternatives, retained table isolation, all 15 old predicates and cleanup.
   Check the new subpartition metadata queries. Run only these lab tests and the
   existing phase/final-observation tests affected by the conversion.
3. Run these three cases together, once, on the forward MyISAM/default/SQL
   profile with coverage. One fixture must serve all three. Use existing failure
   output and support bundles if a case fails. Verify both offline replay stops,
   resume offsets, saved schemas, DONE intents and retained-table cleanup.
4. Compare the matrix and catalog before and after. Keep case obligations,
   exclusions and group membership unchanged. Record SQL calls and separate
   setup, case, coverage-export and cleanup time. Coverage from this three-case
   run cannot establish parity against the full saved partition group.
5. Leave other profiles, the full suite and whole-group timing to CI. Unit tests
   must preserve the unchanged transactional CREATE alternative. Add another
   local profile only if new evidence identifies a profile-specific failure.
   Do not run the syntax suite or performance benchmarks for this lab change.

Focused integration command for the implementation step:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-partition-hash-forms --case ddl-compat-subpartitions --case ddl-compat-partition-expressions --coverage"
```

After this conversion, review partition column renames and column bounds. Then
review KEY algorithms, maintenance and unchecked exchange. Keep their distinct
restart, replay and recovery checks. Do not rebalance jobs or choose the final
short PR selection in this slice.


## Implementation and focused results

Implemented on 2026-11-02. The three cases now use 11 body batches and final
observations. All 38 original operations, both HASH/KEY CREATE alternatives,
15 original predicates and eight live restarts remain. The two replay calls
now repeat the final observations. Their stop point remains transaction three.
No production replication code changed.

All three cases passed in one forward MyISAM/default/SQL fixture with coverage:

| Case | Saved CI client calls | New client calls | Local case seconds | Named assertions |
|---|---:|---:|---:|---:|
| HASH/KEY forms | 127 | 50 | 26.52 | 20 |
| Subpartitions | 287 | 71 | 49.66 | 72 |
| Expressions and bounds | 224 | 74 | 37.42 | 44 |

The combined client count fell from 638 to 195. These are harness calls, not
applier target statements. The old times came from CI and the new times came
from a local machine. They do not establish a controlled elapsed-time speedup.
The subpartition case uses the conservative 170-operation sequence. Its measured
cost does not justify removing retained states in this slice.

All 136 named assertions passed. They include 61 explicit final queries, the
full schema/row comparisons, all eight restarts and 50 repeated replay queries
and comparisons. Both replay runs stopped after three transactions with the
expected GTID set and file offset. They resumed to all 36 expression operations
and all 170 subpartition operations. Their source addresses were unreachable.
Read-only SQLite checks confirmed the final offsets, applied groups, DONE DDL
intents, saved subpartitions and evaluated bound `739982`.

The full comparisons covered six HASH/KEY tables, 37 subpartition tables and
10 expression tables. Raw table metadata confirmed InnoDB on source/native
and MyISAM on target. Each case removed its retained tables. Saved-schema
restart and fixture cleanup passed.

The fixture used 17 source phases: 11 body batches, three setup batches and
three cleanup batches. Setup took 14.87s, including 12.03s for container startup
and 2.28s for database setup. Coverage export took 11.66s. Fixture cleanup took
10.55s. Dependency build layers were reused.

Combined runtime coverage was 9,858 of 20,880 mapped lines. The saved CI report
covers the full partition group, not these three cases alone. No per-case
coverage parity claim follows from that comparison. SQL and predicate audits
confirm that the original conditions remain.

All 18 focused Swift tests and 18 feature/migration tool tests passed. The DDL
catalog check and formatting checks passed. The matrix remains at 183 jobs,
1,545 obligations and 182 coverage collections. Execution groups and profile
exclusions are unchanged. The catalog now lists the named final predicates.
No other profile, full suite, syntax suite or benchmark ran.

Evidence:

- `artifacts/lab/20261102T173725Z-62daa299/result.json`
- `artifacts/partition-forms-workflow-review/results.json`
- `artifacts/partition-forms-workflow-review/state-results.json`
- `artifacts/partition-forms-workflow-review/source-preservation.json`
- `artifacts/partition-forms-workflow-review/matrix-comparison.json`
- `artifacts/partition-forms-workflow-review/unit.log`

Next: review partition column renames and column bounds using saved SQL,
assertions and timings. Map their distinct rename syntax, row routing, encoded
bounds and restart/replay checks before implementation. Keep the full matrix
for CI. Do not rebalance jobs or select the final short PR list yet.
