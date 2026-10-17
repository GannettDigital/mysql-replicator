# DDL completion checklist

This checklist replaces broad next-step labels with specific work items.
The baseline is branch 57. The table retains those historical labels. They are
not the current unsupported-feature list. A completed row needs parser tests,
native evidence,
and applicable shared live, saved-state restart and replay tests. Error cases
must retain the checkpoint and record whether target SQL was sent.

The scope is application DDL on the four declared profiles. Review the pinned
5.7 and 8.4 source before classifying a restriction. A successful parse does not
prove correct schema prediction or restart behavior.

## Implementation and test work

| ID | Specific forms or behavior | Baseline status | Required result |
| --- | --- | --- | --- |
| D01 | Column UNIQUE, UNIQUE KEY, KEY, SERIAL and SERIAL DEFAULT VALUE; unnamed-key naming | Missing forms | Preserve native keys, nullability and row identity in CREATE, ADD, MODIFY and CHANGE. |
| D02 | ADD [COLUMN] (column definitions and keys); DROP COLUMN RESTRICT/CASCADE | Missing forms | Predict the complete schema, independent of key/column clause order. |
| D03 | Index COMMENT, KEY_BLOCK_SIZE, USING placement; primary-key options | Missing forms | Parse the options; let the target apply physical options without losing logical key metadata. |
| D04 | CREATE/DROP INDEX ALGORITHM and LOCK; ALTER with only execution options | Missing forms | Preserve source SQL and native target errors. No extra target statements. |
| D05 | ALTER TABLE RENAME [TO/AS], including other ALTER actions | Selected forms tested in branch 60 | Journal old/new names, changed columns and affected FKs as one source statement. |
| D06 | ALTER ORDER BY, validation options, physical column attributes and remaining table options | Needs native audit | Enumerate accepted forms. Separate application DDL from file/server administration. |
| D07 | 8.4 invisible indexes and SRID metadata on existing targets | Missing metadata/forms | Keep these attributes during discovery, schema changes, restart and replay. Reject unsupported target-version forms specifically. |
| D08 | Generated/default expressions: remaining functions and operators, column placement, native-valid compound dependencies | Partial | Make an explicit syntax inventory; compare native metadata and values for each added form. |
| D09 | Partition expressions/bounds and remaining partition options | Partial | Enumerate missing forms from pinned grammar; test native bounds, metadata and subsequent rows. |
| D10 | FULLTEXT last-index replacement after deletes | Native investigation | Explain the reproduced native document-ID behavior; keep it separate from a replication defect. |
| D11 | Views/routines: absent definers, privilege errors, version-specific bodies, partial source failures | Partial | Record accepted and rejected outcomes. Preserve partial-source changes only with a justified recovery design. |
| D12 | Temporary-table cleanup and CHECK version rules | Implemented subset | Enumerate remaining logged forms. Keep source GTID and target-version restrictions separate. |
| D13 | Interrupted DDL, filters and FK changes for the added forms | Partial | Verify durable before/after schemas and useful support bundles. Do not retry uncertain DDL blindly. |
| D15 | Simultaneous column-name swaps and chains | Implemented in branch 66 | Original column identities; one key/FK mapping; focused restart and replay tests. |
| D16 | Partition-column renames with replacement or removal | Implemented in branch 67 | Match native dependency rules, trailing syntax, row movement, restart and replay. |
| D14 | Primary-key prefixes and 8.4 descending primary-key parts | Implemented in branch 62; integration qualification pending | Preserve key-part metadata in discovery, schema changes and SQLite; retain exact row matching. |

Branch 59 implements selected D01–D04 forms and physical column attributes from
D06. See [the column/index tests](COLUMN_INDEX_SYNTAX.md). Branch 61 adds grouped FK/CHECK clauses
and native unnamed-key boundary rules. See [the scope](GROUPED_CONSTRAINTS_AND_NAMES.md). Do not mark a
whole row complete from a selected happy-path run.

Branch 60 implements standalone and compound table renames. All four profiles
pass live, restart and replay checks. A separate 8.4 refusal test checks a native
parent-column rename defect before target SQL. See [rename results](COMPOUND_TABLE_RENAMES.md).
Branch 63 adds RENAME COLUMN translation and further ALTER options. See
[the ALTER scope](REMAINING_ALTER_FORMS.md). Native failure and physical-option
qualification is specific to each target engine.

Native grammar references include 5.7 `sql/sql_yacc.yy`: `field_option`,
`create_field_list`, `key_options`, `alter_list_item`, `opt_index_lock_algorithm`
and `create_table_option`. Check the corresponding 8.4 rules for version changes.
These rows are a work inventory, not a claim of complete grammar coverage.
Add a concrete row when the audit finds another application DDL form.

## Original delivery order

1. D01–D04: common column and index syntax. Keep typed syntax helpers in
   MySQLSyntax and schema effects in ReplicatorApply.
2. D05–D07: rename transitions, physical options and target-only metadata.
3. D08–D12: finish the native syntax and behavior audit; implement each eligible gap.
4. D13 and full release validation on one build. Reuse valid existing evidence.

Row-image variants, tagged GTIDs and XA are future work by user decision.
See [future binlog work](FUTURE_BINLOG_SUPPORT.md). This deferral does not make a
full-MySQL-support claim valid. Compression and checksum modes also remain open;
this DDL effort does not implement them.

## Branches 61–65 assessment

- D01–D04: grouped constraints and native unnamed-index rules are implemented.
- D05–D06: column rename translation, ORDER BY, validation and physical options
  are implemented. Native physical/plugin restrictions still apply.
- D07/D14: index visibility, column SRID and primary-key parts are saved and
  checked. Legacy schemas remain readable.
- D08–D12: the [native audit](DDL_NATIVE_AUDIT.md) records syntax additions,
  absent-definer behavior, temporary cleanup and native FULLTEXT findings.
- D13: focused tests include restart and offline replay. Existing pending-DDL
  and checkpoint-failure unit tests remain. Full failure-matrix qualification
  is assigned to GitHub.

Keep implementation status separate from release qualification. Broad expression
and partition rows need further tests; they do not identify a specific unsupported
form on their own. Partial source DDL errors remain a specific tool limit.
Branch 69 adds [executable version comments](EXECUTABLE_COMMENTS.md), with native
target gates and separate test qualification. See [support status](../docs/SUPPORT.md#support-status).
The exact native FULLTEXT allocator defect is not fixed or fully traced by this work.

D15 is implemented in branch 66. See [column-swap scope and tests](SIMULTANEOUS_COLUMN_RENAMES.md).
Full release checks must still qualify the combined beta.6 changes.

D16 is implemented in branch 67. See [partition-column renames](PARTITION_COLUMN_RENAMES.md).
