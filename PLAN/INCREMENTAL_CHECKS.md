# Incremental DDL/DML checks

Full checks remain `make ddl-suite` and `make dml-suite`. Selection operates on
independent fixtures or dependent workload slices; it does not skip arbitrary
SQL statements inside a workload and leave later cases without their schema/data.
All commands below run from the repository root. SwiftPM owns the runner; Make
forwards `ARGS`. Docker's existing mapped build caches remain in use.

```sh
# List slices and individually selectable case IDs, names and definition locations.
make ddl-suite ARGS='--list'
make dml-suite ARGS='--list'

# Just the recently added MODIFY/index coverage, one positioning profile.
make ddl-suite ARGS='--slice modify-index --positioning gtid'

# Just the exact demo regression and its operation-specific following row checks.
make ddl-suite ARGS='--case ddl-modify-demo-varchar-120 --positioning gtid'

# Repeat selected independent fixtures against the SAME source/build inputs.
make ddl-suite ARGS='--skip-build --case ddl-index-create --case ddl-index-rename --positioning gtid'

# Other slices. Omit --positioning to run both profiles.
make ddl-suite ARGS='--slice filters'
make ddl-suite ARGS='--slice database --positioning file-position'
make ddl-suite ARGS='--slice ordered --positioning gtid'
make dml-suite ARGS='--slice basic --positioning gtid'
```

`--positioning` accepts `both` (default), `gtid` or `file-position`. The DDL
profiles also exercise FULL and MINIMAL row metadata respectively. All selected
runs still provision disposable source 8.4, native MyISAM 8.4 and Swift MyISAM
5.7 servers. They run the basic four-transaction DML comparison (`positive`) as
an explicit common prerequisite, then only the selected slice/cases. This saves
workload time; container startup still has a fixed cost. Suites run profiles
sequentially to limit Docker memory pressure.

DDL slices:

| Slice | Included work |
| --- | --- |
| `all` | Full suite (default) |
| `basic` | Four-transaction INSERT/UPDATE/DELETE comparison only |
| `modify-index` | Independent MODIFY/index fixtures, target failures, timeout and indexed resume |
| `database` | Database/schema creation fixtures and their rejections |
| `ordered` | Existing ordered schema/DML chain and dependent rejection cases |
| `filters` | Wildcard exclusion/native comparison and saved-checkpoint resume |

`--case ID` can be repeated for the independent MODIFY/index fixtures printed by
`--list`. It selects the `modify-index` slice automatically and rejects unknown
IDs or conflicting slice selections **before building/starting Docker**.
`ddl-index-resume` automatically includes its `ddl-index-create` prerequisite.
Selecting `ddl-index-create` alone does not run the resume case. The DML-only
suite offers `all` and `basic`; its other fixtures retain their dependent chain.
Native-only `make native-ddl-suite` remains a full reference run.

Builds are incremental by default. Use `--skip-build` only when the image was
built from the exact current source/test/harness inputs. DDL evidence validates
the input digest, so code changes require rebuilding; a stale image cannot
produce qualified evidence. Documentation-only changes do not invalidate it.

Every run writes `result.json` with `selection` (slice, requested IDs, positioning,
prerequisites and `full_suite`), `cases.json` with only cases actually executed,
and the existing diagnostics/binlog/SQLite artifacts. A selected pass means
**the selected checks passed**, not that the complete suite passed. Coverage
bundles still contain only measured assertions; omitted cases add no coverage.
Import them through `make ddl-catalog-report ARGS='--evidence PATH'` as before.

Unit tests can also run selectively, without Docker:

```sh
swift test --filter SchemaChangeTests
swift test --filter TableFilterTests
swift test --filter SuiteSelectionTests
```

If Rust changed, rebuild its archive first (`cargo build --manifest-path
rust/Cargo.toml --locked`). `make test` remains the full Rust/Swift check and
ensures externally linked archives are picked up.

## Validation, 2026-10-01

143 Swift and 2 Rust tests passed. The filter slice passed four named cases in
each positioning mode. The isolated `ddl-modify-demo-varchar-120` GTID run passed
exactly two cases (requested case plus `positive`), with five named assertions
for the MODIFY case. All three stacks cleaned up and retained matching input
hashes. Catalog import accepted the selected bundles without qualifying omitted
cases. Local logs and run IDs: `artifacts/incremental-filters-20261001/`.
Full suites were not rerun for this slice.
