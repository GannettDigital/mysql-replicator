# Compound foreign-key index changes

Branch: `beta/6/54-compound-foreign-key-indexes`, based on branch 53.

## Native behavior

A target clone can contain an explicit index where the source has an automatic
FK index. information_schema does not report the automatic flag. MySQL can keep
an explicit index or replace an automatic index with the new constraint's index.
This can occur more than once in a compound ALTER.

Disposable probes on 5.7.42 and 8.4.8 confirmed:

- ADD FOREIGN KEY with ADD COLUMN can replace an old automatic index.
- Two FK additions on different columns can replace two indexes.
- Two FK additions on the same columns can leave the last constraint's index.
- RENAME INDEX makes the index explicit; the new FK reuses it.
- A wider explicit index can remove a redundant automatic index.
- An explicit matching index remains when a new FK uses it.
- FK clauses can precede their supporting-index DROP or new column definition.

Local upstream references: MySQL 5.7 `sql/sql_table.cc`, generated-key pruning
near lines 3944–3970 and the RENAME INDEX flag change near line 8388. MySQL 8.4
uses the same distinction between explicit and automatic supporting indexes.

## Planner and journal

The planner resolves FK additions after the statement's column and index changes.
It records `supportingIndexReplacements` in each affected schema
transition. Each record contains one exact planned index and one exact alternative.
Only matching, nonunique BTREE definitions qualify. Explicit additions and
renames are protected. The alternatives do not change column definitions or FKs.

After execution, a bounded matching algorithm assigns each actual replacement
to one planned index. It cannot use one replacement to hide two missing indexes.
Recorded optional index removals can occur in the same ALTER. Every other schema
field must match. The applier then saves the actual target schema.

Sixteen independent replacements need sixteen records, rather than every
combination of sixteen full-table snapshots. The existing table/index limits
bound the matching work. Row application does not use this algorithm.

The optional field needs no SQLite table migration. Old `afterAlternatives`
records remain readable. New DDL uses the compact records. An uncertain DDL
still blocks and requires DBA review; this change does not add automatic retry.

## Verification

The selected apply and lab unit run passed 494 tests. New tests check independent
replacements, exact schema checks, explicit-index protection, required versus
optional indexes, duplicate matching and old journal decoding.

The shared `ddl-compat-foreign-key-compound-indexes` workflow checks FK/index/column
combinations, two independent replacements, same-column FK additions, renamed
indexes, explicit indexes and a wider index. It also checks cascades, restart,
replay, the pending index-choice records and the saved actual target index.

Periphery passed. Both InnoDB profiles passed the final compound workflow,
including restart and replay (31 steps per profile):

- 5.7 → 8.4: `artifacts/lab/20261016T051019Z-c40568a3/result.json`.
- 5.7 → 5.7: `artifacts/lab/20261016T051242Z-4a21080f/result.json`.

Both runs used binary SHA-256
`cc90ad18d6eda037be4ee18f8136bed93a214a22d84f0710de94408d996310ad`.

Before the final clause-order change, both profiles also passed the generated-FK
regression case and the initial compound case (52 steps per profile):
`artifacts/lab/20261016T050055Z-d87c5b68/result.json` and
`artifacts/lab/20261016T050253Z-6498f492/result.json`.
Those runs used binary SHA-256
`740cbba8cd3d13dc194c17abfe475dd9d9ecf3cc732b9f7f77b56c344076b49d`.
These were selected tests, not the full correctness matrix.

## Remaining scope

This increment qualifies the listed compound forms. It does not qualify every
ALTER grammar combination. Branch 55 adds [inline primary-key column additions
and implicit values](ALTER_COLUMN_KEYS.md). Branch 56 adds selected
[generated-column dependency changes](GENERATED_COLUMN_DEPENDENCIES.md).
Other column conversions and expression combinations remain in the complete support plan.
Native engine restrictions still apply.
