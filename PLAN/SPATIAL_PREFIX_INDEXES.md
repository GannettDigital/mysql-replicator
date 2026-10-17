# Geometry BTREE prefix indexes

Status: implementation on `beta/6/34-spatial-prefix-indexes`. Focused integration
checks passed on both applicable 5.7 target profiles. This is a version-specific index form, separate from SPATIAL
indexes and their bounding-box searches.

Native 5.7.42 accepts `KEY by_g(g(32))` for a GEOMETRY column on InnoDB and
MyISAM. It also accepts a compound index such as `KEY by_g(g(16),id)`. Native
8.4.8 rejects the prefix with error 1089. The native check is in `sql_table.cc`,
where 8.4 rejects a specified key-part length for `MYSQL_TYPE_GEOMETRY`.

The schema model accepts a positive geometry byte prefix. The 5.7 target still
checks engine key-length and uniqueness limits. The 8.4 target contract rejects
this form before application DDL, with the index and column names. The applier
does not convert it to a SPATIAL index or remove it.

The shared case applies to the two 5.7 source → 5.7 target profiles. It checks
CREATE, INSERT, UPDATE, DELETE, prefix changes, a compound index, CREATE LIKE
and saved-schema restart. It compares index metadata and native spatial bytes.
The 8.4 source and target exclusions state the native error. Unit checks cover
all eight geometry types, durable schema encoding and the target-version gate.

## Combined fixed-input confirmation

Run `20261015T073916Z-20bde8e4` passed at stack commit `735d35b`. It ran
21 applicable charset, generated-expression and geometry-prefix cases across
the four profiles. Three cases were excluded for native version restrictions.
The outer lab result passed. All 421 build inputs stayed unchanged. The
build-input digest is
`a1782ef199a53cf7e0991118ce527af8ea37a84dd158574bef32c58bf045b82d`.
This is selected-case evidence, not full feature or release qualification.
