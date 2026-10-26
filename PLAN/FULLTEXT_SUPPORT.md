# FULLTEXT indexes

Status: implemented subset. Full catalog qualification remains open.

## Scope

The applier accepts FULLTEXT definitions in CREATE TABLE, ALTER TABLE ADD and
CREATE INDEX. It also accepts DROP and RENAME INDEX. CREATE TABLE LIKE retains
the index metadata. Tables still need a supported primary key.

Native discovery reads index type FULLTEXT, NULL sort direction and NULL prefix.
MySQL ignores a declared FULLTEXT prefix. The saved schema uses the native
result. STATISTICS has no parser-plugin column. The applier reads that attribute
from SHOW CREATE TABLE during discovery and schema checks. It caches the result
with the table schema. DML does not add a per-row metadata query.

`WITH PARSER` is retained in the saved schema and checked after DDL and restart.
The parser plugin must exist on the target. Source SQL stays unchanged. Version
comments in native SHOW CREATE output are read as metadata only. This does not
remove the existing restriction on executable comments in source DDL.

## Native limits and differences

Both pinned versions require CHAR, VARCHAR or TEXT columns with one collation
per FULLTEXT index. Binary and wide character sets are not accepted. Virtual
generated columns are not accepted. These restrictions come from native index
validation. They do not classify a rejected source statement as an apply gap.

MySQL 5.7 ignores explicit ASC/DESC on FULLTEXT index parts. MySQL 8.4 rejects
explicit index order with error 1221. The applier does not remove that syntax
from source SQL. A 5.7 to 8.4 stream that uses it can therefore fail on the target.
Both versions reject FULLTEXT USING BTREE.

Use compatible parser plugins, token sizes, stopword settings and collations.
Support for the index does not make search results equal across all server
versions, settings or storage engines. Default-parser and ngram tests use
selected terms with explicit result checks. Other plugins and the full grammar
still need qualification.

## Selected tests

- `ddl-compat-fulltext`: inline and standalone CREATE, ADD, DROP and RENAME,
  ignored prefixes, default parser, ngram, CREATE TABLE LIKE, following DML and
  restart before row changes.
- The ngram CREATE, INSERT, UPDATE and DELETE assertions now run in
  `ddl-compat-fulltext`. They replace the replicated `matrix-fulltext` case.
  See [the consolidation review](BETA7_TEST_SUITE_CONSOLIDATION.md).
- `bootstrap-matrix-fulltext`: initial discovery of an existing ngram index,
  row changes and saved-schema restart.

All 401 selected apply and lab unit tests passed. After the fixture correction,
all 96 lab tests passed. The 17 CI-matrix tests also passed. All four profiles passed 23 selected
integration steps each, including saved-schema restart.
The initial unit run found errors in the new catalog classifications. These
were corrected before integration tests.

## Passing integration runs

Each run selected `ddl-compat-fulltext`, `matrix-fulltext` and
`bootstrap-matrix-fulltext`. Results are under `artifacts/lab/`.

| Profile | Run |
| --- | --- |
| `mysql84-to-mysql57-myisam` | `20261014T214128Z-c8e7d4e8` |
| `mysql57-to-mysql84-innodb` | `20261014T214209Z-dbc4dfb5` |
| `mysql57-to-mysql57-myisam` | `20261014T214232Z-706caac1` |
| `mysql57-to-mysql57-innodb` | `20261014T214239Z-8b66ed0e` |

All runs used input digest
`d390a0a0c34970b9a6ef24345b8cf00857afc5257bb8b7395ba7127192c03ef2`.
These selected cases do not qualify all parser plugins, charsets, options,
failure outcomes or offline replay paths.

## Native source references

The local source revisions are 5.7
`f7680e98b6bbe3500399fbad465d08a6b75d7a5c` and 8.4
`0896fcd61dec11a0904166911a0126f59daaa1bf`.

- `sql/sql_table.cc`: FULLTEXT field, charset and prefix validation.
- `sql/sql_show.cc`: SHOW CREATE index and parser output.
- `sql/sql_yacc.yy`: FULLTEXT syntax and index options.

Direct probes used MySQL 5.7.42 and 8.4.8. See the support catalog for the
remaining assertions. Selected success cases do not qualify all failure paths.

## Native search observation during fixture review

The first six runs stopped on a source search assertion. The applier did not
enter BLOCKED, so no automatic support bundle was expected. After UPDATE,
DELETE and replacement of the last FULLTEXT index, the source stored a new row
but did not find it with MATCH. Both source versions showed this behavior.

A direct MySQL 8.4.8 InnoDB probe reproduced the sequence without the replicator.
The native FT index assigned document ID 6 to the new row. ID 6 also remained in
INNODB_FT_DELETED. A second new row used document ID 7 and matched. This explains
the observed omission. Changing the search term did not fix the first new row.
A fresh table with an ngram index matched both terms. The precise native code
path that reuses the deleted document ID still needs review.

The fixture now tests ADD WITH PARSER on a separate table. Default-parser
UPDATE/DELETE assertions remain. Last-index replacement after deletions remains
an explicit native-behavior investigation, not a passed search guarantee.
Do not classify the source's omission as a replication transport failure.

The failed run directories remain under `artifacts/lab/`:

- `20261014T212013Z-27d494c1` and `20261014T212046Z-afd17b5b`.
- `20261014T212548Z-2feb16cd` and `20261014T212552Z-8da99428`.
- `20261014T212619Z-c6d97ceb` and `20261014T212623Z-e1db906d`.

These runs are not qualification evidence. They preserve the SQL, source/native/
target comparisons, run logs and fixture state from the failure.

A later DML fixture used `quartz`, `cobalt` and `silver mineral` with ngram.
After deleting the cobalt row, native MyISAM still matched that query against
remaining text. InnoDB did not. The failed evidence is in
`20261014T213235Z-585f8280` and `20261014T213303Z-ac19e822`. The test now uses
`xyzzy`, `qqvvq` and `rrwwr`, which have distinct ngram tokens. Direct probes
passed INSERT/UPDATE/DELETE assertions on both engines in 5.7.42 and 8.4.8.
This tests index maintenance without assuming equal search semantics for all
stopwords and terms. The earlier InnoDB runs passed all 23 steps:
`20261014T213236Z-72db0fc4` and `20261014T213307Z-3fd0787f`.

A reproduction on a disposable MySQL 8.4.8 server:

```sql
CREATE DATABASE fulltext_native_case;
CREATE TABLE fulltext_native_case.t (
  id INT PRIMARY KEY, title VARCHAR(80), body TEXT,
  FULLTEXT KEY ft(title(2), body)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
INSERT INTO fulltext_native_case.t VALUES
  (1,'quartz','cobalt mineral'),(2,'granite','silver mineral');
UPDATE fulltext_native_case.t SET title='granite',body='cobalt mineral' WHERE id=1;
DROP INDEX ft ON fulltext_native_case.t;
CREATE FULLTEXT INDEX ft ON fulltext_native_case.t(body);
ALTER TABLE fulltext_native_case.t RENAME INDEX ft TO ft_renamed;
UPDATE fulltext_native_case.t SET body='quartz mineral' WHERE id=2;
DELETE FROM fulltext_native_case.t WHERE id=2;
ALTER TABLE fulltext_native_case.t DROP INDEX ft_renamed,
  ADD FULLTEXT KEY ft(body) WITH PARSER ngram;
INSERT INTO fulltext_native_case.t VALUES
  (3,'quartz','quartz mineral'),(4,'xyzzy','xyzzy mineral');
SELECT id,body,MATCH(body) AGAINST('quartz' IN BOOLEAN MODE),
  MATCH(body) AGAINST('xyzzy' IN BOOLEAN MODE) FROM fulltext_native_case.t;
SET GLOBAL innodb_ft_aux_table='fulltext_native_case/t';
SELECT DOC_ID FROM information_schema.INNODB_FT_DELETED;
SELECT WORD,DOC_ID FROM information_schema.INNODB_FT_INDEX_CACHE
  WHERE WORD IN ('qu','xy');
SELECT WORD,DOC_ID FROM information_schema.INNODB_FT_INDEX_TABLE
  WHERE WORD IN ('qu','xy');
```

The index entries can move from INDEX_CACHE to INDEX_TABLE. Inspect both.
The FT inspection variable requires administrative access. Reset it to its
previous value after the probe.

## Replacement-state review

Branch 65 repeats the native reproduction and reviews the replacement code.
The common deletion state survives a same-ALTER replacement. The probe again
finds new document ID 6 in the deleted list, while ID 7 matches. See
[the code-path review](DDL_NATIVE_AUDIT.md#fulltext). The exact allocator cause
still requires an instrumented native server. No replicator workaround is added.
