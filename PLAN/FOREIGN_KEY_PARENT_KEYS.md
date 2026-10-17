# Native InnoDB parent-key rules

Branch: `beta/6/50-native-parent-key-rules`, based on branch 49.

## Native behavior

MySQL 5.7 InnoDB accepts full leading columns of a parent index. The index can
be nonunique. The reference can use only the first columns of a composite key.
InnoDB also considers clustered-key columns that it appends to secondary indexes.
A byte-prefix index, such as `KEY(name(5))`, is not a full-column FK index.

MySQL 8.4 clients default to `restrict_fk_on_non_standard_key=ON`. However, native
replica SQL threads and parallel workers set this option to OFF. The applier now
uses that same session setting on each MySQL 8.4 InnoDB connection.

Local upstream references:

- MySQL 5.7 `storage/innobase/dict/dict0dict.cc`: `dict_foreign_find_index` and
  `dict_foreign_qualify_index` match full leading index columns.
- MySQL 8.4 `sql/rpl_replica.cc`, near lines 6059 and 7092: both replica thread
  paths set `restrict_fk_on_non_standard_key` to false.
- MySQL 8.4 `sql/sql_table.cc`: `find_fk_parent_key`,
  `fk_key_is_full_prefix_match`, and extended parent-key handling.
- MySQL 8.4 `sql/sys_vars.cc`: the option is a session variable.

Disposable probes confirmed nonunique and extended parent keys. A parent with
no suitable index still failed, including with `foreign_key_checks=0`.

## Implementation

`NativeReplicationRules` selects the parent-key policy and the version-specific
session SQL. MySQL 5.7 needs no extra session statement. Metadata validation and
DDL planning use the same parent-key rule.

The applier accepts full leading BTREE columns and possible clustered-key
extensions. Without an explicit primary key, SQL metadata does not identify
which eligible unique index InnoDB promoted. The planner considers the possible
keys and lets the target validate the actual index. It does not assume that the
applier's selected row lookup key is the physical clustered key.

Parent and child column checks, filters, relationship limits and durable schema
transitions remain in effect. The target enforces FK actions and errors. The
applier does not generate cascade statements. For example, a native cascade can
delete child rows when one of two matching nonunique parent rows is deleted.

No SQLite schema change or new configuration option is required. The session
setting is applied again after a target reconnect.

## Verification

Selected apply and lab unit tests: 483 passed. Periphery found no unused code.
The shared `ddl-compat-foreign-key-parent-keys` workflow checks:

- Nonunique parent indexes, duplicate parents and native cascade behavior.
- References to leading columns of a composite primary key.
- Secondary indexes extended by an explicit or promoted clustered key.
- CREATE and ALTER ADD FOREIGN KEY, parent-index changes, restart and replay.

The former nonunique-key rejection tests now remove the supporting index only
on the target. They check rejection before SQL, an unchanged checkpoint and
support-bundle contents. The native reference still accepts the source sequence.
Both InnoDB profiles passed the parent-key workflow, `reject-foreign-key` and
`foreign-key-safety`. Each run completed 35 reported workflow steps, plus the
rejection and safety assertions. The full profile matrix was not run.

| Profile | Local artifact root |
| --- | --- |
| 5.7 → 8.4 InnoDB | `artifacts/lab/20261016T040104Z-9655b5fb` |
| 5.7 → 5.7 InnoDB | `artifacts/lab/20261016T040701Z-a917e649` |

Both runs used binary SHA-256
`efd3cdde9e5a26f88c694d1437ad699c58dbd266cd6cfc827e7da83ce5f12cb5`.

## Remaining limits

Branch 53 adds [stored generated FK columns](GENERATED_COLUMN_FOREIGN_KEYS.md).
Some compound index changes still need review.
Branch 52 adds [cross-database DROP](CROSS_DATABASE_FOREIGN_KEYS.md). Partitioned InnoDB FK tables remain subject to native engine
restrictions. Branch 51 adds [MATCH, names and column rules](FOREIGN_KEY_SYNTAX_COLUMNS.md).
