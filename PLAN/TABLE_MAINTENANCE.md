# ALTER table maintenance

Branch: `beta/6/35-table-maintenance`.

The typed syntax target accepts FORCE, ENABLE KEYS and DISABLE KEYS as complete
ALTER actions. The applier uses the normal DDL barrier, journal and schema
comparison. It sends the source SQL to the target. These actions do not change
column or constraint definitions, so they do not need new durable schema fields.

The target engine performs the operation. MyISAM disables nonunique indexes for
DISABLE KEYS. ENABLE KEYS rebuilds those indexes. InnoDB does not disable its
indexes for this clause. FORCE rebuilds the table. Native engine warnings and
errors still apply. The tool does not emulate engine behavior.

Native references: `sql/sql_yacc.yy` ALTER productions in the pinned MySQL 5.7
and 8.4 trees. A direct 5.7.42 MyISAM probe confirmed `disabled` in
`information_schema.STATISTICS.COMMENT` for an ordinary nonunique index.

## Checks

The shared `ddl-compat-table-maintenance` case checks disabled index state,
row changes while the index is disabled, indexed reads after ENABLE KEYS,
generated column values after FORCE, a compound ALTER and restart.

Four focused parser tests and 97 catalog/lab unit tests passed. The independent
syntax target has 23 tests and 611/614 executable lines covered (99.51%).
The corrected run `20261015T082226Z-16bb3eb7` passed on all four profiles,
with 15 steps per profile. Its input-stability check passed. The input digest
is `b2504c30cf0a8d3221caff56ab497720628d5d4e319360ae9a9dcdbe89bacbd6`.

These checks do not complete the remaining ALTER or partition operations.

## Initial test correction

Run `20261015T080407Z-fe0a4dcd` passed three profiles. The 5.7 to 5.7 MyISAM
profile failed a native assertion on STATISTICS.COMMENT. The applier did not
enter BLOCKED. The retained comparison showed equal rows and schema.

A direct 5.7 probe returned stale index state from INFORMATION_SCHEMA.STATISTICS
while SHOW INDEX showed `disabled`. The fixture now uses SHOW INDEX and compares
the index name, type and state. It retains the full raw output in the evidence.
InnoDB and MyISAM have separate state expectations. It also checks indexed reads
after ENABLE KEYS. The corrected harness passed 101 selected unit tests.
