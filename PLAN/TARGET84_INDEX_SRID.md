# MySQL 8.4 index visibility and spatial reference constraints

Branch: `beta/6/64-target84-index-srid`.

The applier reads IS_VISIBLE from STATISTICS and SRS_ID from COLUMNS on 8.4.
It saves both fields with the table schema. Old saved schemas remain readable:
missing visibility means visible; a missing SRID means no column constraint.
No SQLite migration or per-row metadata query is required.

CREATE/ADD INDEX accepts VISIBLE and INVISIBLE. ALTER INDEX changes visibility.
RENAME INDEX and column changes retain visibility. A primary key cannot be
invisible. MySQL 5.7 targets reject visibility syntax and column SRID constraints
with specific version errors. The native target checks SRS existence, coordinate
rules and whether an index is required by a foreign key.

Spatial row transport retains native binary geometry, including its SRID.
The applier does not change coordinates or assign another SRID. A constrained
target column can therefore reject a row accepted by an unconstrained source.
This is a target schema restriction.

The native 8.4.8 probe confirms SRID 0, NULL for an unconstrained column,
IS_VISIBLE values, and a 32-byte spatial index bounding-box prefix.
Nineteen selected unit tests pass. Tests cover parsing, version errors, saved
metadata, legacy defaults and index renames. The shared case
`target84-index-spatial-metadata` starts with an enhanced 8.4 target. It checks
raw geometry bytes, index renames, following rows, restart and offline replay.
It passed on `mysql57-to-mysql84-innodb` in run
`20261016T175556Z-c45d133e`, including live DML/ALTER, restart and replay.
The integration case uses SRID 0. Unit parsing also covers SRID 4326; this
does not qualify every geographic SRS or coordinate boundary.
