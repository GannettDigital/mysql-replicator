# Primary-key parts

Branch: beta/6/62-primary-key-parts.

The saved schema can now retain primary-key prefix lengths and sort directions.
Old schemas without primaryKeyParts still mean full ascending columns. Schema
comparison, CREATE LIKE, renames, column changes, key replacement and partition
exchange retain or compare this metadata. No SQLite table migration is required.

Row lookup still uses each complete source key value. A unique prefix also makes
the complete value unique; lookup must not truncate the supplied value. TEXT/BLOB
primary keys require a prefix. Native engine key-length limits still apply.
Prefix keys do not qualify as complete FK indexes. Descending parts follow the
target version: 5.7 stores accepted DESC syntax as ascending; 8.4 retains DESC.

MySQL 5.7 can return NULL direction in a limited information_schema query that
reads only .frm metadata. BTREE parts on 5.7 are always ascending. Discovery
normalizes that case. It does not normalize an unknown 8.4 direction.

Direct probes on 5.7.42 and 8.4.8, with InnoDB and MyISAM, passed prefix-key
updates, prefix-length changes and column renames. The selected regression run
passed 95 tests. Five primary-key tests passed after the direction adjustment.
Tests cover legacy and new saved schemas, validation, FK eligibility and full
key lookup. The shared ddl-compat-primary-key-parts case covers all four profiles,
restart and replay. Full integration qualification remains with GitHub.

The forward primary-key case passed in `20261016T173456Z-5a4bc05a`.
The later column-rename case failed in that run; the primary-key result is
separate evidence, not a claim that the entire run passed.
