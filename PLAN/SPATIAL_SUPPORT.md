# Spatial columns

The applier accepts GEOMETRY, POINT, LINESTRING, POLYGON, MULTIPOINT,
MULTILINESTRING, MULTIPOLYGON, and GEOMETRYCOLLECTION. It treats the MySQL 8.4
name GEOMCOLLECTION as GEOMETRYCOLLECTION.

## Native representation

Both source trees store spatial values as a four-byte little-endian SRID,
followed by WKB. See `Field_geom::store_internal` in `sql/field.cc` in
`.upstream/mysql-server` and `.upstream/mysql-server-5.7`. The binlog table map
uses `MYSQL_TYPE_GEOMETRY` with a four-byte value length. MySQL 8.4 FULL metadata
can also carry the declared geometry subtype.

The decoder copies these bytes. The applier sends a binary SQL parameter.
It does not convert through WKT or change the coordinate order. The target's
normal spatial validation still applies. If subtype metadata is present,
it must match the target column. A MySQL 5.7 source or MINIMAL metadata does not
supply this subtype list; the saved table schema supplies the column type.

MySQL 8.4 can interpret geographic SRIDs differently from MySQL 5.7. Equal
stored bytes do not guarantee equal spatial function results. For example,
WKT output for SRID 4326 can use a different axis order. This implementation
does not transform coordinates or map spatial reference systems.

## DDL and limits

CREATE TABLE, ADD/MODIFY columns, and the existing table lifecycle operations
accept these types. SPATIAL indexes can be declared in CREATE TABLE, added by
ALTER TABLE or CREATE SPATIAL INDEX, and removed by DROP INDEX. Both versions
report the implicit 32-byte bounding box as index SUB_PART. Discovery removes
that implicit size before comparing the index with its DDL declaration.

The supported SPATIAL index has one NOT NULL column and is not unique.
MySQL 5.7 geometry BTREE byte-prefix indexes are a separate supported form.
MySQL 8.4 rejects that form with native error 1089. See the
[prefix-index note](SPATIAL_PREFIX_INDEXES.md).

Column SRID constraints follow the target version. MySQL 5.7 does not support
them. The reverse profile tests an existing 8.4 target POINT with SRID 0, a
SPATIAL index and an invisible ordinary index. It checks DML, ALTER, restart
and replay. This does not test every SRID or geometry subtype combination.

Non-NULL spatial defaults require a parenthesized expression on a target that
supports expression defaults. MySQL 5.7 does not support expression defaults.
The ordinary spatial value case has no spatial defaults and uses an integer
primary key. It does not test geometry primary keys or spatial default expressions.
The configured event, transaction and SQL packet limits also apply.

Legacy JSON opaque values with type GEOMETRY are a separate representation.
This change does not add an exact SQL constructor for that JSON subtype.

## Tests

Unit tests check optional subtype metadata, adjacent text metadata, all three
row operations, NULL, malformed lengths, DDL, and saved schema round trips.
The shared matrix-spatial case checks all eight declarations, empty collections,
SRIDs 0 and 4326, key changes, column changes and SPATIAL indexes on all four
profiles. The former bootstrap-matrix-spatial entry is replaced by the focused
metadata-columns-indexes case. It reads the original schema and uses only the
first INSERT to trigger discovery.

The value case uses preparation/body batches and three retained tables. Final
queries check complete Cartesian geometry bytes, NULL/empty values, SRIDs,
POINT coordinates, declarations and index replacement. Exact stored bytes,
including geographic point order, still enter the source/native/target comparison.
See [the lab guide](../docs/TEST_LAB.md#spatial-values-and-indexes).

All three Spatial Data Types cases share the data-types-values CI fixture:
matrix-spatial, ddl-compat-spatial-prefix-indexes and
target84-index-spatial-metadata. Native version exclusions and deliberate
restart/replay steps remain. The following run records predate this batching
change. Its focused measurements are recorded in the
[type/value workflow review](BETA7_DATA_TYPE_VALUE_WORKFLOW_REVIEW.md).

The selected cases passed on all four profiles. The forward profile also passed
with file positions and MINIMAL metadata. Local result directories under
`artifacts/lab/`:

| Profile / variant | Run |
| --- | --- |
| 8.4 → 5.7 MyISAM / default | `20261014T032204Z-76417829` |
| 5.7 → 8.4 InnoDB / default | `20261014T032651Z-d9f42782` |
| 5.7 → 5.7 MyISAM / default | `20261014T032759Z-966f8269` |
| 5.7 → 5.7 InnoDB / default | `20261014T033030Z-a33024f5` |
| 8.4 → 5.7 MyISAM / position-minimal | `20261014T033055Z-6659cd19` |

The first reverse run failed in source setup because MySQL 5.7 rejects the WKT
form `GEOMETRYCOLLECTION EMPTY`. The fixture now uses `GeometryCollection()`.
The forward default run predates that fixture-only correction. The MINIMAL run
and all MySQL 5.7 source runs use the corrected fixture. No applier change was
needed for that correction.

The 396 affected Swift unit tests, nine Rust tests, catalog validation, and
17 CI matrix tests also passed. Full regression checks remain assigned to CI.

## Beta.6 index extension

The later [geometry prefix-index increment](SPATIAL_PREFIX_INDEXES.md) adds
ordinary BTREE byte prefixes for MySQL 5.7 targets. It keeps MySQL 8.4's native
rejection separate from missing implementation. Use that note for the current
prefix-index status and evidence.
