# Foreign-key DDL transitions

Branch: `beta/6/48-foreign-key-ddl`, based on branch 47.

## Scope

This increment adds:

- Supporting-index additions, including standalone CREATE INDEX and compound
  ALTER with an unrelated column-default change.
- Parent and child FK-column renames with CHANGE COLUMN. Self-references and
  incoming references use the same schema transition path.
- DROP DATABASE when every foreign-key relationship stays inside that database.
  The journal records every FK participant, including tables without row events.

## Native behavior

Both local MySQL 5.7 and 8.4 probes accepted this sequence: create a parent and
child; add a wider child index; rename the parent key and child reference column;
drop the database with the relationship still present.

MySQL can remove a generated supporting index when a new BTREE has the same
complete column prefix. It keeps an explicit supporting index. An explicit index
rename clears the generated flag in MySQL 5.7. FULLTEXT and SPATIAL indexes do not
replace FK supporting indexes.

Local source references:

- MySQL 5.7 `sql/sql_table.cc`, near lines 3944–3970: redundant generated keys.
- The same file, near line 8388: RENAME INDEX clears `HA_GENERATED_KEY`.
- MySQL 8.4 retains the same generated-key distinction in its DDL handling.

The generated flag is not exposed by information_schema. A target clone can
also recreate an originally generated index as an explicit index. The applier
must accept either native outcome without accepting unrelated schema changes.

## Durable index outcomes

The pre-DDL journal can now include `removableSupportingIndexes` in a schema
transition. Each entry contains the exact old index definition. An entry must be
a nonunique BTREE that supports an existing FK. A newly added index or primary
key must cover its complete column prefix. Explicitly renamed indexes are not
optional.

After DDL, the applier permits only those recorded removals. It compares every
other schema field exactly. All remaining child relationships must still have
supporting indexes. The applier then saves the exact target schema. This avoids
an exponential list of possible index combinations.

Branch 54 replaces new `afterAlternatives` records with compact
`supportingIndexReplacements`. These support multiple FK additions and mixed
FK/index/column changes. Old records remain readable. See
[compound FK index changes](COMPOUND_FOREIGN_KEY_INDEXES.md).

The new optional field keeps old transition records readable. No SQLite table
migration or automatic DDL retry is added. An uncertain DDL still leaves its
intent pending for DBA review.

## Column and database transitions

CHANGE COLUMN updates child columns and referenced parent columns in the whole
connected relationship component. The journal records the before and after
schemas for the affected tables before it sends DDL. Post-DDL validation checks
these snapshots. A saved-state restart checks the final relationships again.

DROP DATABASE requires global REFERENCES visibility before discovery. Branch 48
rejected cross-database relationships. Branch 52 adds their
[schema transitions](CROSS_DATABASE_FOREIGN_KEYS.md). Metadata comparisons and table
list deduplication use byte values. Names that differ only by case remain
distinct. Internal relationships, including self-references, can be dropped
together. The same GTID retires all affected saved schemas after the server
confirms success.

## Verification

The shared `ddl-compat-foreign-key-ddl` case compares source, native replica and
external target after every step. It checks implicit index removal, explicit
index retention, parent/child/self-reference renames, later cascades, DROP
DATABASE, schema retirement, restart, and offline replay with no source access.
The drop includes three baseline FK tables with no captured events. The journal
must contain all three. Two names differ only by case on case-sensitive servers.

`foreign-key-safety` also checks a cross-database DROP. Branch 52 changes this
case to an unexpected incoming FK on the target only. The source and native
replica accept the DROP. The applier rejects it before an execution intent.
It leaves the rows and checkpoint unchanged.
The case uses database names that differ only by case where the server permits it.

Selected apply/lab unit tests passed: 477 tests. Periphery found no unused code.
Final shared runs passed with the case-sensitive metadata checks. Each profile
ran `ddl-compat-foreign-key-ddl` and `foreign-key-safety`. Each run completed
26 reported workflow steps, plus the safety assertions.

| Profile | Local artifact root | Result |
| --- | --- | --- |
| 5.7 → 8.4 InnoDB | `artifacts/lab/20261016T025533Z-755a64d9` | Passed |
| 5.7 → 5.7 InnoDB | `artifacts/lab/20261016T025738Z-4f92bc62` | Passed |

Both runs used binary SHA-256
`37c80c5d599027d51cc20438940fd2b7c9002df9872eb4f99642381ff1bf982a`.
This increment did not run the full profile matrix.

MySQLSyntax did not change. Its separate suite is not required for this increment.

## Remaining gaps

Branch 49 adds [missing-parent tables](MISSING_PARENT_FOREIGN_KEYS.md).
Branch 50 adds [native parent-key rules](FOREIGN_KEY_PARENT_KEYS.md).
Branch 52 adds cross-database DROP dependency transitions. Branch 53 adds
[stored generated FK columns](GENERATED_COLUMN_FOREIGN_KEYS.md). Branch 54 adds
[compound index changes](COMPOUND_FOREIGN_KEY_INDEXES.md). Other ALTER forms still
need qualification.
Partitioned FK tables remain subject to native engine restrictions.
