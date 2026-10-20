# DDL native audit

Branch: `beta/6/65-ddl-native-audit`.

This audit covers the remaining DDL groups in the agreed work order. It compares
our parser with the pinned 5.7 and 8.4 grammar and selected native results. It is
not proof that every MySQL statement or stored-program body is qualified.
Full release qualification belongs to GitHub.

## Expression and partition forms

| Form | Result |
| --- | --- |
| Ordinary function calls | The expression parser accepts function names and arguments. The target checks function eligibility for generated columns, defaults and indexes. |
| CASE, predicates, bit operators, CAST/CONVERT, date arithmetic | Existing typed expression support remains. The shared generated-expression case checks native values and following rows. |
| INTERVAL(n,a,b) | Added. It differs from the duration form INTERVAL (n+1) DAY. Native 5.7.42 and 8.4.8 both accept the function in generated columns. |
| CAST(value AS YEAR) | Added to expression syntax and metadata parsing. Native 8.4 accepts it. This does not make the expression valid on 5.7. |
| STATS_SAMPLE_PAGES=DEFAULT | Added. Both native grammars accept DEFAULT. |
| UNION=() | Added as a physical table option. The native target checks the selected engine. |
| Partition ENGINE, COMMENT, DATA/INDEX DIRECTORY, MAX_ROWS, MIN_ROWS, TABLESPACE, NODEGROUP | Already parsed by SQLPartitionClause. Physical options remain in target SQL. They do not change row decoding. |
| HASH/KEY, RANGE/LIST, COLUMNS, subpartitions and KEY ALGORITHM | Existing schema prediction and native bound evaluation remain. See the partition plans for qualified forms. |
| DROP/REBUILD PARTITION followed by COMMENT in the same ALTER | Both pinned servers reject the tested form with error 1064. Do not add this as a missing application feature. |

The syntax inventory is in MySQLSyntax. Do not create a function-name allowlist
that rejects a valid native expression merely because no dedicated test names it.
New MySQL grammar still requires a parser test and native metadata comparison.
The audit does not qualify every function, plugin or cross-version semantic change.

## Definers and privileges

Both native versions allow a privileged account to create a view or routine with
an absent definer. Creation emits note 1449. SQL SECURITY INVOKER uses the caller.
SQL SECURITY DEFINER fails with error 1449 when the object is invoked.
The applier retains the definer and security mode. It must not replace a definer
with the apply account.

On 8.4, SET_ANY_DEFINER alone does not permit an absent definer. A restricted
native probe returned error 1227 and named SUPER or ALLOW_NONEXISTENT_DEFINER.
Grant the required privilege on the target if the source uses these objects.
The project does not replicate accounts or grants. Target privilege errors use
the existing failed-DDL path and do not advance the applied checkpoint.

The shared `ddl-compat-absent-definers` case checks metadata, invoker results,
error 1449, unchanged binlog positions after failed invocation, restart and
replay. Stored-program bodies stay as original SQL. Target version checks remain
native. Parsing a routine header does not certify every possible body.

## Temporary objects and partial source failures

ROW logging carries changes to permanent tables. Temporary objects are not
copied. The existing temporary CTAS case checks their permanent row effects.
The 5.7 conditional DROP TEMPORARY TABLE IF EXISTS cleanup is skipped. It cannot
drop a permanent object. Other temporary statements remain outside apply support.
See `sql_base.cc::close_temporary_tables` and DROP handling in `sql_table.cc` in
the 5.7 tree. CHECK clauses from sources before 8.0.16 retain the existing native
ignore rule. Enforced 8.4 checks cannot be preserved on a 5.7 target.

A source Query event with a nonzero error code is rejected before filtering or
target execution. A partly successful source statement needs object-specific
reconciliation. Retrying the full statement cannot safely infer the source's
partial result. This is a tool limit, not a claim that native replication rejects
all such events. The error includes the source error code. Do not broaden this
policy without a durable partial-result design.

## FULLTEXT

The documented replacement-after-delete sequence reproduces directly on 8.4.8.
The row with document ID 6 has an index entry for `qu`, but ID 6 remains in
INNODB_FT_DELETED. The next row uses ID 7 and matches `xyzzy`. This separates the
native search omission from row transport.

Relevant pinned 8.4 code:

- `handler/handler0alter.cc` passes `adding_fts_index` to `fts_drop_index`.
- `fts/fts0fts.cc::fts_drop_index` clears common tables only for the last index
  when no replacement is being added. A same-ALTER replacement keeps common
  deletion state. The other branch preserves cached document-ID counters.
- `ddl/ddl0builder.cc` chooses a generated or fetched document-ID sequence.
- `fts/fts0fts.cc` updates the synchronized and next document-ID counters.

These paths explain which state survives replacement. The probe proves the
collision between a new index entry and retained deletion state. It does not
prove the exact allocator instruction that selected the reused ID. That needs
an instrumented native server. Keep the reproduction and native limitation;
do not add a target-only rebuild that would change source/native behavior.

Raw probe output stays under `artifacts/beta6-validation/`. The original failed
integration runs remain listed in [the FULLTEXT plan](FULLTEXT_SUPPORT.md).

## Simultaneous column names

Native probes accept this name swap:

```sql
-- MySQL 8.4
ALTER TABLE t RENAME COLUMN a TO b, RENAME COLUMN b TO a;
-- MySQL 5.7
ALTER TABLE t CHANGE a b INT, CHANGE b a BIGINT;
```

The values stay with their original columns. Existing index `ka(a)` becomes
`ka(b)`; index `kb(b)` becomes `kb(a)`. The audit found that the schema predictor
applied each change in sequence and rejected the first duplicate destination.

Branch 66 replaces that sequence with original column identities and one final
name mapping. It updates primary keys, secondary indexes and FK peers together.
See [the implementation and tests](SIMULTANEOUS_COLUMN_RENAMES.md). This closes
the identified swap gap. It does not establish complete DDL coverage.

## Focused verification

- 42 isolated syntax tests pass. Syntax line coverage is 1,012/1,020 (99.22%).
- The apply/lab regression run passed 524 of 525 tests. The remaining test
  lacked REPLICATOR_TEST_BINARY_DIR. With that path set, all 106 selected lab
  and support-bundle tests passed. After the final charset-order correction,
  all 111 selected ALTER, metadata and lab tests passed.
- Periphery reports no unused code in the final build index.
- Reverse run `20261016T175556Z-c45d133e` passes absent definers, generated
  expressions, grouped constraints and target 8.4 metadata. Its 37 steps include
  saved-state restart and offline replay with an unreachable source.
- Forward run `20261016T180509Z-25434f85` passes both ALTER cases (23 steps).
- Reverse run `20261016T180825Z-69588c2c` passes the InnoDB options case
  (12 steps). Both final runs include saved-state restart and offline replay.

The first ALTER runs found a translation-order error and invalid fixture SQL.
The next options run found a native MyISAM restriction. Those failures remain
in their artifact directories. They are not counted as passing qualification.
Full release qualification is left to GitHub by user decision.
