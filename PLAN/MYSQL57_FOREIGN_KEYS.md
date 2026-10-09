# MySQL 5.7 foreign keys and reverse replication

Status: proposed follow-up to the shared reverse correctness suite. No foreign-key
support is enabled by this note.

## Scope and current behavior

Both MySQL 5.7 and 8.4 support foreign keys on InnoDB. The current rejection is
an applier limitation, not a general incompatibility between those versions.
The intended topology is 5.7 InnoDB → external applier → 8.4 InnoDB, compared
against a native 5.7 InnoDB replica of the same source.

The reverse target contract currently rejects tables with outgoing or incoming
foreign keys. The DDL parser also rejects foreign-key definitions. Target sessions
enable `foreign_key_checks`; the transaction assembler rejects row-event flags
other than `STMT_END`, including the flag indicating disabled FK checks.

## MySQL behavior to preserve

- InnoDB implements `RESTRICT`/`NO ACTION`, `CASCADE`, and `SET NULL`. Constraints
  are checked immediately, rather than deferred until transaction commit.
- InnoDB cascade effects are not separate binlog row events. Deleting a parent
  with `ON DELETE CASCADE` logs the parent change; the destination's matching
  foreign key must cause the child deletions. The same dependency matters for
  cascading updates. Do not treat these effects like separately logged trigger
  row changes or disable target FK checks globally.
- Native replication restores the source's foreign-key-check setting from row
  event flags. Supporting source sessions with checks disabled needs explicit
  handling; otherwise retain a clear rejection.
- Matching destination relationships are part of the replication contract.
  Missing or different constraints can omit cascades or change their effects.
  Bootstrap must preserve those definitions, and replication filters must not
  silently exclude tables required by a relationship.
- MySQL 5.7 permits foreign keys referencing non-unique indexes and certain
  partial keys. MySQL 8.4 restricts that legacy extension by default through
  `restrict_fk_on_non_standard_key`. Start with references to complete primary
  or unique keys; reject incompatible definitions explicitly.

## Proposed implementation

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
5. Handle source `foreign_key_checks=0` as a separate qualified extension, or
   retain its explicit refusal. Do not silently force different source semantics.

## Correctness tests

Extend `make reverse-correctness` with source-side FK DDL and compare parent and
child schemas/data on source 5.7, native 5.7, and external target 8.4. Cover:

- Single-column and composite references to primary/unique keys.
- Parent/child inserts and explicit deletes in one transaction.
- `RESTRICT`, delete/update `CASCADE`, and `SET NULL`, including cascade chains.
- Self-references as a separate qualification case before claiming support.
- Constraint add/drop, supporting indexes, table rename, and saved-schema restart.
- Rejection of incompatible target constraints and unsupported legacy references.
- Target-side constraint failure with complete transaction rollback; recovery
  inspection that exposes possible cascade effects after an uncertain commit.
- Source checks-disabled events: correct handling if implemented, otherwise
  rejection without advancing past the event.

## References

- [MySQL 5.7 foreign-key constraints](https://dev.mysql.com/doc/refman/5.7/en/constraint-foreign-key.html)
- [InnoDB replication and unlogged cascade effects](https://dev.mysql.com/doc/refman/8.4/en/innodb-and-mysql-replication.html)
- [MySQL 8.4 foreign-key requirements and restrictions](https://dev.mysql.com/doc/refman/8.4/en/create-table-foreign-keys.html)
- Pinned source: `Rows_log_event::do_apply_event` in both upstream versions'
  `sql/log_event.cc` restores `NO_FOREIGN_KEY_CHECKS_F` for row application.
- [Reverse replication plan](INNODB_REVERSE_REPLICATION.md)
