# Column and index syntax

Branch: `beta/6/59-column-index-syntax`, based on the DDL checklist branch.

## Native evidence and implementation

Direct probes on MySQL 5.7.42 and 8.4.8 confirmed:

- A column KEY attribute creates a primary key. UNIQUE and UNIQUE KEY create
  secondary unique indexes. UNIQUE alone does not force NOT NULL.
- SERIAL is BIGINT UNSIGNED NOT NULL AUTO_INCREMENT with a unique index.
  SERIAL DEFAULT VALUE adds the auto-increment and unique attributes to the
  declared type.
- MODIFY with an inline UNIQUE attribute adds an index. It does not replace
  an existing index. Native names can be `a`, `a_2`, then `a_3`.
- Ordinary unnamed indexes receive names in declaration order. An explicit
  duplicate name remains an error. Functional-index naming uses its existing
  separate rule.
- ADD COLUMN can contain a parenthesized list of column and index definitions.
- DROP COLUMN accepts RESTRICT and CASCADE. These words do not enable automatic
  removal of dependencies that the native server would reject.
- Index comments, KEY_BLOCK_SIZE and USING options are accepted. The target
  engine applies physical options. For example, the tested 8.4 InnoDB server
  omits KEY_BLOCK_SIZE from SHOW CREATE where 5.7 retains it.
- CREATE and DROP INDEX accept ALGORITHM and LOCK. ALTER TABLE can contain an
  execution option without a separate schema-change clause.
- COLUMN_FORMAT and STORAGE are physical column attributes. They do not change
  the logical row schema in the tested cases.

`SQLDDLOption` parses one bounded option in MySQLSyntax. It does not know the
server version or engine. ReplicatorApply selects valid contexts and applies
version rules. The original SQL retains comments and physical/execution options.
The target executes one source statement. No new durable-state format is needed.

The existing index model's parser-only name flag now also covers unnamed ordinary
indexes. CREATE resolves these names in declaration order. ALTER resolves added
keys against the resulting table. Saved schemas do not contain unresolved names.

## Tests

The new shared case is `ddl-compat-column-index-syntax`. It covers inline keys,
grouped ADD, repeated unique-key additions, physical attributes, index options,
execution options, serial values, later DML, saved-state restart and offline replay.

The isolated syntax run passed 39 tests with 967/973 executable lines covered
(99.38%). The first apply/lab run exposed old expectations for unnamed keys and
HASH rejection, plus the missing catalog registration for the new case.
After these were updated, all 36 selected affected tests passed. The other tests
in the 509-test run passed. Periphery passed.

All four selected integration runs passed 25 steps each, including saved-state
restart and offline replay:

| Profile | Result under `artifacts/lab/` |
| --- | --- |
| 8.4 → 5.7 MyISAM | `20261016T160942Z-cc30f338/result.json` |
| 5.7 → 8.4 InnoDB | `20261016T161126Z-782d05b5/result.json` |
| 5.7 → 5.7 MyISAM | `20261016T161414Z-031649f8/result.json` |
| 5.7 → 5.7 InnoDB | `20261016T161459Z-a769b531/result.json` |

All used binary SHA-256
`ac7c4103fb6458c179a7a6b9e31ad1bec1a613b0d6ae757e41a23b3e17238891`.
These are selected cases, not full release qualification.

## Remaining checklist work

This increment does not complete all DDL. Parenthesized ADD groups containing
FK or CHECK constraints still need explicit handling. Primary-key prefix metadata,
compound table renames, and the other checklist entries remain separate work.
See [the DDL checklist](DDL_COMPLETION_CHECKLIST.md).
