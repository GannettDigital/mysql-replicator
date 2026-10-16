# MySQL 5.7 foreign keys and reverse replication

Status: implemented for the stated rules in `mysql57-to-mysql84-innodb`
and `mysql57-to-mysql57-innodb`. Selected tests pass. The complete relationship
and failure matrix is not release-qualified. See [status definitions](../docs/SUPPORT.md#support-status).
Validation results are recorded below.

## Scope and current behavior

Both MySQL 5.7 and 8.4 support foreign keys on InnoDB. Support is restricted to
relationships whose effects can be preserved by the target.
Both profiles use a 5.7 InnoDB source and a native 5.7 InnoDB reference.
The external target is 8.4 or 5.7 InnoDB, as selected by the profile.

The InnoDB target contract discovers both outgoing and incoming relationships.
Each saved table schema includes its complete connected relationship component,
including ordered columns and update/delete rules. Target sessions restore the
source `foreign_key_checks` setting for row events and DDL. MyISAM
profiles retain the foreign-key DDL refusal.

## MySQL behavior to preserve

- InnoDB implements `RESTRICT`/`NO ACTION`, `CASCADE`, and `SET NULL`. Constraints
  are checked immediately, rather than deferred until transaction commit.
- InnoDB cascade effects are not separate binlog row events. Deleting a parent
  with `ON DELETE CASCADE` logs the parent change; the destination's matching
  foreign key must cause the child deletions. The same dependency matters for
  cascading updates. Do not treat these effects like separately logged trigger
  row changes or disable target FK checks globally.
- Native replication restores the source's foreign-key-check setting from row
  event flags. The applier retains the setting for each mutation.
- Matching destination relationships are part of the replication contract.
  Missing or different constraints can omit cascades or change their effects.
  Bootstrap must preserve those definitions, and replication filters must not
  silently exclude tables required by a relationship.
- MySQL 5.7 permits foreign keys referencing non-unique indexes and certain
  partial keys. MySQL 8.4 client sessions restrict that extension by default.
  Native replica threads disable `restrict_fk_on_non_standard_key`. Branch 50
  uses the same session setting and [parent-key rules](FOREIGN_KEY_PARENT_KEYS.md).

## Implementation

1. Extend the schema model and SQLite schema history with constraint names,
   ordered child/reference columns, referenced tables, and update/delete actions.
   Discover and verify incoming and outgoing relationships, including supporting
   indexes. Keep engine/version rules in the target contract.
2. Add CREATE TABLE and ALTER TABLE ADD/DROP FOREIGN KEY handling to the existing
   ordered, journaled DDL path. Account for automatically created supporting
   indexes and dependent schema-cache invalidation on ALTER/RENAME/DROP.
3. Qualify ordered DML with checks enabled first. Let target InnoDB enforce
   constraints and perform cascades inside the existing source-transaction
   boundary. Remove the blanket rejection only for qualified relationships.
4. Make recovery inspection identify relationships whose child rows may have
   changed implicitly. Current row images describe explicit binlog mutations;
   they cannot reconstruct every cascaded child's before/after image. Give the
   DBA enough context to inspect or restore affected tables without presenting
   that evidence as proof of commit or complete automatic recovery.
5. Restore source `foreign_key_checks` from row and Query events. See
   [the extension and remaining limits](FOREIGN_KEY_CONTROLS.md).

## Correctness tests

Run the shared profile suite:

```sh
make correctness PROFILE=mysql57-to-mysql84-innodb ARGS="--family foreign-keys"
```

Compare parent and child schemas/data on source 5.7, native 5.7, and external
target 8.4. The suite covers:

- Single-column and composite references to primary/unique keys.
- Parent/child inserts and explicit deletes in one transaction.
- `RESTRICT`, delete/update `CASCADE`, and `SET NULL`, including cascade chains.
- Self-references and cycles use the `ddl-compat-foreign-key-controls` workflow.
  Graph unit tests cover filter splits, nonunique/partial keys and saved schemas.
- Constraint add/drop, supporting indexes, table rename, and saved-schema restart.
- Rejection of incompatible target constraints. Nonunique, leading composite
  and extended parent keys use the implemented native parent-key rules.
- Target-side constraint failure with complete transaction rollback; recovery
  inspection that exposes possible cascade effects after an uncertain commit.
- Source check settings, including changes within a transaction and offline replay.

## Bounds and operational contract

- All participating tables need supported columns and no target triggers.
  Parent indexes follow [native InnoDB rules](FOREIGN_KEY_PARENT_KEYS.md).
  Missing-parent behavior is described [here](MISSING_PARENT_FOREIGN_KEYS.md). FK
  columns follow [native storage and collation rules](FOREIGN_KEY_SYNTAX_COLUMNS.md).
  Stored generated FK columns use [native action limits](GENERATED_COLUMN_FOREIGN_KEYS.md).
  Virtual FK columns and partitioned participants have native restrictions.
  Self-references and cycles are supported.
- Components are bounded to 64 tables and 256 relationships. Metadata work occurs
  at discovery, restart and DDL barriers; it is not a per-row check.
- The target account needs explicit global `REFERENCES` privilege so metadata discovery
  cannot silently miss incoming relationships. Normal per-table schema visibility
  and trigger visibility are still required.
- Bootstrap must preserve source constraints. Inspecting a target clone cannot
  prove that it has the same relationships as its source; this remains an operator
  responsibility, including offline replay.
- CREATE/ALTER ADD/DROP FOREIGN KEY, automatic child indexes, CREATE LIKE (without
  copied constraints), table rename and dependency-ordered DROP are supported.
  FK-column renames, supporting-index additions and DROP DATABASE with internal
  or external relationships are implemented. The journal records permitted removals
  of generated supporting indexes, then saves the exact target result.
  See [FK DDL transitions](FOREIGN_KEY_DDL.md) for scope and tests.
  See [cross-database DROP](CROSS_DATABASE_FOREIGN_KEYS.md) for source check
  requirements. Branch 54 adds [compound index changes](COMPOUND_FOREIGN_KEY_INDEXES.md).
  ADD FOREIGN KEY can replace equal, nonunique automatic supporting indexes.
  The journal records exact `supportingIndexReplacements` before execution.
  Post-DDL validation matches these choices and saves the actual schema.
  Other column, index or constraint differences still fail.
- FOREIGN KEY index names can appear without an explicit CONSTRAINT name. The
  server generates the constraint name. MySQL 5.7 MATCH clauses ignore following
  actions. The applier preserves that behavior on both InnoDB targets.
- DDL updates relationship snapshots and invalidates prepared plans for affected
  tables at a drained barrier. Autocommit and multi-row INSERT execution retain
  source transaction boundaries; prepared queues do not reorder writes.
- Recovery exposes `foreignKeyRelationships` for the entire component, including
  indirect child tables. These are candidate reconciliation tables, not child
  before/after images or proof of a target commit. Automatic recovery is unchanged.

## Validation (2026-10-10)

- Swift unit suite: 396 tests passed. This includes graph and parser checks,
  schema-history compatibility, index alternatives, and uncertain-commit recovery
  evidence with an indirect cascade relationship.
- Shared `foreign-keys` family: both scenarios passed against source/native MySQL
  5.7 and target MySQL 8.4. The positive workflow made 37 source-side steps. Safety
  cases cover nonunique references, filter splits in DDL and discovery, explicit
  rollback and autocommit FK errors, checks-disabled DDL/rows, and saved-schema
  drift on restart. Recovery inspection runs without a network connection.
- Evidence: `artifacts/lab/20261010T174319Z-6276095b/result.json`.
  Runtime binary SHA-256:
  `702adde8efc2adff7c17f105983908cabed6edbc8fb5fcda007651002e658020`.
- The generated-index workflow verified that the pre-write DDL journal contained
  the permitted alternative and that the completed schema saved the actual
  `restored_fk` index, matching both source and native.
- Existing regression cases passed on all three profiles: `positive`,
  `matrix-composite`, `ddl-index-create`, `ddl-compat-database`, and
  `reject-foreign-key` (15 scenario results; 29 workflow steps per profile).
  These runs used the same runtime binary as the FK suite. Evidence:
  `artifacts/lab/20261010T174907Z-3c0d0dec/result.json` (8.4 → 5.7 MyISAM),
  `artifacts/lab/20261010T174909Z-30772826/result.json` (5.7 → 5.7 MyISAM),
  `artifacts/lab/20261010T175116Z-43ca1592/result.json` (5.7 → 8.4 InnoDB).
  The complete pre-existing catalog and lifecycle variants were not rerun here.
- CI matrix planning passed: the new area is present in the applicable profile
  variants. The matrix ownership tests passed (9 tests).

## References

- [MySQL 5.7 foreign-key constraints](https://dev.mysql.com/doc/refman/5.7/en/constraint-foreign-key.html)
- [InnoDB replication and unlogged cascade effects](https://docs.oracle.com/en/middleware/goldengate/core/19.1/ggcab/disabling-triggers-and-cascade-constraints-mysql-and-mariadb.html)
- [MySQL 8.4 foreign-key requirements and restrictions](https://dev.mysql.com/doc/refman/8.4/en/create-table-foreign-keys.html)
- Pinned source: `Rows_log_event::do_apply_event` in both upstream versions'
  `sql/log_event.cc` restores `NO_FOREIGN_KEY_CHECKS_F` for row application.
- [Reverse replication plan](INNODB_REVERSE_REPLICATION.md)
