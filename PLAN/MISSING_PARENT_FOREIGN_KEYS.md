# Missing-parent foreign keys

Branch: `beta/6/49-missing-parent-foreign-keys`, based on branch 48.

## Native behavior

MySQL 5.7 and 8.4 retain KEY_COLUMN_USAGE and REFERENTIAL_CONSTRAINTS records
when a parent table is absent. With `foreign_key_checks=0`, both versions permit
creation of the child before the parent and permit a parent table drop.

Enabling checks does not remove the relationship or scan existing orphan rows.
A NULL reference, a change to an unrelated column, and a child delete can still
succeed. A new non-NULL reference must pass the target's normal FK checks.

Local references are MySQL 5.7 `storage/innobase/dict/dict0dict.cc`
(`dict_foreign_add_to_cache`, missing referenced-table handling) and the MySQL
8.4 dictionary FK handling. Disposable probes checked both server versions.

## Implementation

Keep each FK edge in the saved table schema, even if its parent does not exist.
Do not invent a schema for an absent table. Discovery reads existing related
tables and validates the child columns, supporting indexes and table filters.
It validates parent columns and keys when the parent exists.

DDL planning permits a newly absent parent when the source disabled checks.
An existing missing-parent relationship can remain during unrelated DDL.
Creating a parent discovers its incoming relationships before execution.
Dropping a parent retains the child edges and retires the parent's saved schema.
DROP DATABASE skips absent parent names when it records existing FK tables.

The existing DDL transition records contain the relationships. There is no
SQLite format change. Restart accepts valid missing-parent metadata. It does
not disable row checks: each row event retains the source check setting, and
the target enforces that setting. No automatic orphan repair is added.

## Verification

Selected apply and lab unit tests: 479 passed.
The shared `ddl-compat-foreign-key-missing-parent` case covers CREATE and ALTER,
parent drop and recreation, child DML, cascades, restart, and offline replay.
Replay stops after two transactions, while the parent is absent, then resumes.
The test also checks that the pre-DDL journal retains the unresolved relationship.
Both InnoDB profiles passed 28 workflow steps, including restart and replay.
Periphery found no unused code. The full profile matrix was not run.

| Profile | Local artifact root |
| --- | --- |
| 5.7 → 8.4 InnoDB | `artifacts/lab/20261016T035018Z-7d8b10f6` |
| 5.7 → 5.7 InnoDB | `artifacts/lab/20261016T035220Z-6f68eeb6` |

Both runs used binary SHA-256
`1d8201044175821111e4bd122c1625293bf0d92fd3d5492d492c4d81caad663a`.

Branch 50 adds [native parent-key rules](FOREIGN_KEY_PARENT_KEYS.md).
Branch 52 adds [cross-database DROP](CROSS_DATABASE_FOREIGN_KEYS.md).
Branch 53 adds [stored generated FK columns](GENERATED_COLUMN_FOREIGN_KEYS.md).
