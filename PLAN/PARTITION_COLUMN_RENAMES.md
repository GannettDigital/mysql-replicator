# Partition-column renames

Branch: `beta/6/67-partition-column-renames`.

## Native rule

A column used by a partition or subpartition expression can be renamed when
the same ALTER replaces or removes partitioning. The new partition definition
uses final column names. The native server rebuilds the table as required.

```sql
ALTER TABLE t
  CHANGE a b INT
  PARTITION BY RANGE(b) (
    PARTITION p0 VALUES LESS THAN(10),
    PARTITION p1 VALUES LESS THAN MAXVALUE
  );
```

There is no comma before this trailing PARTITION BY clause. The same trailing
form accepts REMOVE PARTITIONING. MySQL 8.4 also permits RENAME COLUMN in this
statement. The existing translation preserves the definition on a 5.7 target.

An unchanged partition expression cannot retain a renamed or dropped column.
This is a native restriction. Implicit KEY() partitioning follows the primary
key and has no explicit column name to replace. Explicit KEY(column) does.

References: local `sql/sql_table.cc` in the pinned 5.7 and 8.4 source trees.
The 8.4 helper is `check_if_field_used_by_partitioning_func`. Direct probes on
5.7.42 and 8.4.8 confirm replacement, removal, subpartition names and row values.

## Implementation

The DDL parser accepts the trailing partition clause. A separate
`PartitionColumnDependencies` check examines the whole ALTER. It permits a
rename or drop when partitioning is replaced or removed. Otherwise, it checks
both partition and subpartition expressions before target SQL.

The applier does not rename identifiers inside a partition expression. It uses
the source's new definition. The target checks that definition against the
final schema. One source ALTER still produces one target ALTER.

The existing DDL journal retains the old and proposed schemas, including all
partition metadata. This work does not change the state format or automatic
recovery rules. Uncertain DDL still requires DBA review.

## Tests

- Unit tests check trailing syntax, replacements, removal, simultaneous column
  names, implicit KEY, unchanged dependencies and serialized metadata.
- `ddl-compat-partition-column-renames` checks all four profiles. It includes
  subpartition changes, swaps, row movement, removal, implicit KEY, later DML,
  saved-state restart and offline replay.
- `ddl-compat-partition-rename-syntax` checks the RENAME COLUMN translation from
  an 8.4 source, with replacement, removal, row changes, restart and replay.
- The forward native reference uses InnoDB for these cases. MySQL 8.4 does not
  support MyISAM partitioning. The 5.7 external target still uses MyISAM.

Full release qualification remains assigned to GitHub.

## Verification

The CHANGE workflow passed live, saved-state restart and offline replay checks
on all four profiles in `20261016T185313Z-096c1cd5`. Each profile recorded 18
steps. The aggregate run failed in the separate forward RENAME COLUMN case.
Its bundle shows `notIssued`: the native SHOW CREATE partition comment stopped
metadata parsing before target SQL. The saved schema and checkpoint stayed at
the previous operation. The original failed evidence is retained.

The fix enables the existing native-metadata comment mode only for this
SHOW CREATE read. Source executable comments remain rejected. A unit regression
checks both paths and preserves comment-like bytes inside a column literal.
The final focused unit run passed 47 tests. The earlier apply/lab selection
passed 159 tests before this metadata-read adjustment.

The final forward rerun `20261016T191409Z-9e954b4d` passed both selected cases,
including live checks, saved-state restart and offline stop/resume. The other
three profile results above cover CHANGE on 5.7 sources; those sources have no
RENAME COLUMN syntax. The metadata-read fix applies to that translation only.
