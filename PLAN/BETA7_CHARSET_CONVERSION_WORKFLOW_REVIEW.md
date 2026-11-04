# Column character set conversion: workflow review

Status: implemented and tested on forward MyISAM. The review below records the
approved design. See [the focused results](#implementation-and-focused-results).

## Decision

Convert only `ddl-compat-charset-conversion` in the next slice. Use four source
body batches and final observations. Keep its ID, group, all four profiles and
the forced FULL row-metadata setting. Preserve all ten original source operations
first, six old predicates and restarts before operations 4, 7 and 9.

Retain three earlier states in separate tables within `ddlcompat`. The proposal
has 24 source operations in batches of 3, 3, 2 and 16. Do not combine source
transactions. The case has no offline replay path today; add none here.
No production conversion, metadata-probe or parser change belongs in this slice.

The initial review used saved evidence. No build or integration test ran during
that review. The preceding
table-default/compound-conversion pair was committed as `b4cc05c`.

## Names and native behavior

Consult the MySQL documentation before naming features. Use
[Column Character Set Conversion](https://dev.mysql.com/doc/refman/8.4/en/charset-conversion.html)
and the character-set conversion section of
[ALTER TABLE](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html).
Use the case title **Column character set conversion: TEXT widening, defaults
and binary values**.

CONVERT TO CHARACTER SET can widen text types to preserve character capacity.
Conversion to binary changes text fields to binary fields. A later table-wide
CONVERT does not turn those existing binary fields back into text. Keep the
original sequence, including its later invalid-UTF-8 bytes, which must remain
valid binary values.

The fixture uses ASCII ENUM/SET labels while VARCHAR and TEXT contain non-ASCII
values. Keep that distinction. The earlier native investigation found source
failures for some non-ASCII label/default conversions. This case does not prove
all label encodings or charset pairs. See [the implementation notes](ALTER_CHARSET.md).

## Saved measurements and source audit

CI run `40454033524`, commit `efb3458`, has no failed or missing shards and no
missing coverage. This case still matches that commit, including its original
SQL, six predicates and restart positions. All four default/SQL runs passed:

| Profile | Case seconds | SQL trace calls |
|---|---:|---:|
| mysql84-to-mysql57-myisam | 47.30 | 222 |
| mysql57-to-mysql84-innodb | 40.28 | 221 |
| mysql57-to-mysql57-myisam | 45.69 | 221 |
| mysql57-to-mysql57-innodb | 40.93 | 221 |

The forward run made 12 schema-comparison requests per role: ten body operations
plus two setup operations. These are harness mysql client calls, not the applier's
native metadata-probe queries. The applier probes converted field definitions
at DDL barriers. Do not remove those probes to improve harness measurements.

Coverage is attributed to the larger character-set area. The
[first review](BETA7_CHARACTER_SET_WORKFLOW_REVIEW.md#coverage-comparison-scope)
records its exact line sets and comparison scope. It cannot identify this case's
individual lines or prove that conversion is redundant with table-default tests.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/charset-conversion-workflow-review/baseline.json`: four saved results.
- `artifacts/charset-conversion-workflow-review/source-review.json`: original SQL,
  predicate map, retained histories, batches, restarts and cleanup.
- `artifacts/charset-conversion-workflow-review/review.py`: reproducible source audit.

## Retained histories

Keep original operations 1–10 first, through deletion of original row 2. Append
these independent histories. Replace only qualified `ddlcompat.t` references
with the retained table name. No extra database is needed.

| Original prefix | Retained table | State kept for final checks |
|---|---|---|
| 1–3 | `cv_after_utf8` | One row immediately after latin1-to-utf8mb4 conversion; widened text metadata and original converted bytes. |
| 1–4 | `cv_after_defaults` | A second row inserted using defaults under the converted UTF-8 schema. |
| 1–7 | `cv_after_binary` | ADD/CONVERT, UPDATE and conversion to binary completed; binary types and row bytes remain before the later overwrite. |
| Original final table | `t` | Later CONVERT and binary UPDATE completed; original row 2 deleted. |

A prefix-3 copy is necessary because the old converted-byte query selects every
row. Prefix 4 adds a second row, so it cannot supply that same result. Keep the
prefix-4 default check before binary conversion. Do not move it to the binary
history merely because its displayed ENUM/SET values can still look the same.
The prefix-7 state is necessary because operation 9 overwrites its earlier bytes.

Preserve complete CREATE definitions, including NOT NULL/defaults, ENUM/SET
member order, TEXT/TINYTEXT, VARBINARY, stored generated g and `by_v(v(8))`.
Preserve every ALTER clause and its order. In particular, keep ADD of an explicit
latin1 column together with CONVERT in original operation 5. Do not replace a
history with a final CREATE or literal rows.

Keep `café`, `été`, `é`, `one`, `a`, `one,a` and `new` exactly. Keep binary literals
X'00FF', X'FE' and X'FF00'. Copy g's unqualified expression `(v)` as written; it
must reference its own retained table's v.

## Six original predicates

Only table references change where an earlier state needs retention:

| Old observation | Final query table | Expected result |
|---|---|---|
| TEXT widening and unaffected binary column after operation 3 | `cv_after_utf8` | tx: mediumtext/utf8mb4_bin; small_tx: text/utf8mb4_bin; b: varbinary/NULL collation. |
| Converted row bytes after operation 3 | `cv_after_utf8` | HEX(v/e/s/tx/b/g): `636166C3A9`, `6F6E65`, `6F6E652C61`, `C3A974C3A9`, `00FF`, `636166C3A9`. |
| Inserted defaults after operation 4 | `cv_after_defaults`, id=2 | HEX(v), e, s: `636166C3A9`, `a`, `a`. |
| Binary types after operation 7 | `cv_after_binary` | v: varbinary; tx: mediumblob; small_tx: blob. |
| Row bytes after operation 7 | `cv_after_binary`, id=1 | HEX(v/tx/b/g): `C3A974C3A9`, `636166C3A9`, `00FF`, `C3A974C3A9`. |
| Final binary UPDATE after operation 9 | Original t, id=1 | HEX(v/tx/b/g): `00FF`, `FE`, `FF00`, `00FF`. |

Retain the original query columns, order, WHERE clauses and expected strings.
Rewrite INFORMATION_SCHEMA TABLE_NAME predicates to the corresponding retained
name. Do not weaken them to counts of columns or non-NULL values. Final queries
must be read-only. Compare full schemas, index definitions and row bytes for
original and retained tables with source/native/target.

Add a final metadata check on original t requiring the binary type signature
above to remain after operation 8. Add a final row-count check requiring id=2
to be absent. These checks supplement the six old predicates. They do not
replace the generated-value, stored-default, label or prefix-index comparisons.

Do not guess a new fixed index prefix width or converted default representation.
Keep the native schema/index comparison. If a new fixed expectation is useful,
obtain it from native evidence before making it an assertion. The original
`by_v(v(8))` declaration must remain in every CREATE.

## Batches, metadata and cleanup

Use these source boundaries:

1. Original operations 1–3.
2. Original operations 4–6, after the first existing restart.
3. Original operations 7–8, after the second existing restart.
4. Original operations 9–10 and all 14 retained operations, after the third restart.

Every Step keeps `transactions: 1`; keep the existing comparison with captured
source progress. Keep source warning capture without introducing an empty-warning
requirement. Default source and target engine selection is unchanged.

Keep `ddl-compat-charset-conversion` in the shared runner's FULL metadata set.
Do not let position/minimal variants change that existing requirement. Keep all
profile selections. This slice does not add a source-session override or old
DEFAULT-name syntax, so no extra reverse run is needed locally.

All four tables must have saved current schemas. Keep all DDL intents DONE,
exact GTIDs and file offsets, original objects and shared saved-schema restart.
There is no case-specific compatibility/no-op count to rescope.

Cleanup occurs after saved-state checks and drops only the three retained tables
in one source operation:

```sql
DROP TABLE ddlcompat.cv_after_utf8,ddlcompat.cv_after_defaults,ddlcompat.cv_after_binary;
```

Do not drop original t or restore the source from a synthetic final state.
Keep the other encoding cases unchanged.

## Measurement tradeoff

The original case executes four CONVERT statements. The retained histories add
five, for nine total. These extra statements exercise real native field probes
and can add target work. Fewer waits and client startups do not guarantee a
lower case time. Record both client calls and elapsed time, including separate
setup, coverage-export and cleanup costs.

Do not discard one of the six predicates or replace native schema checks merely
to make a timing result improve. If the added conversion work dominates, assess
an alternative retained-state method separately with the same original SQL,
transaction/lifecycle conditions and expected results. Do not change production
conversion logic as part of that assessment.

## Focused implementation and validation

1. Convert this case with existing phase/final-observation helpers. Preserve
   original SQL first, all six predicates, three restarts, FULL metadata and
   profile/engine selection. Use the three retained histories above.
2. Add focused lab unit tests for exact source bytes and retained references,
   generated expression/member order/index preservation, all six predicate
   mappings, binary-type persistence, DELETE outcome and cleanup ownership.
   Run affected workflow and phase/final-observation tests only.
3. Run this case once on forward MyISAM/default/SQL with coverage. Read the
   support bundle before a failed-case rerun. Keep other profiles and the full
   suite for GitHub Actions.
4. Inspect source transaction counts, raw engines, saved schemas, completed
   intents, exact GTIDs/offsets, default/generated bytes, native index metadata,
   saved-schema restart and cleanup. Compare matrix/catalog selection. Record
   calls and times without claiming per-case coverage parity with the old area.

Focused command:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-charset-conversion --coverage"
```

No other case/profile, full suite, benchmark, mapping/collision run or syntax
suite is needed locally. Next: review `charset-defaults` with explicit source
session boundaries, then encoded Query SQL and identifier workflows. Keep the
DML inventories, remaining type/value and key/index reviews, full-matrix
validation, final balancing and short PR selection in the overall plan.

## Implementation and focused results

The case now uses four source batches of 3/3/2/16 operations. The first ten SQL
operations remain byte-for-byte unchanged. Three retained tables repeat the
reviewed prefixes. All six old result predicates remain, with only their table
references changed where earlier state must be retained. Two further checks
verify final binary column types and deletion of row 2. The three original
restart points, FULL metadata, all profile selections and engine choices remain.
The other encoding cases and the shared runner are unchanged. No new replay
path or production conversion logic was added.

The focused forward MyISAM/default/SQL run passed all 17 named assertions.
It used one fixture and six source batches: setup, four body batches and cleanup.
Full schema, index and row comparisons included all four tables. Saved-state
inspection confirmed all 24 source GTIDs, exact group file/end offsets, the final
checkpoint, all DDL intents DONE and four current saved schemas. Raw table data
confirmed source InnoDB and native/target MyISAM for all four tables. Saved-schema
restart and cleanup passed. Cleanup dropped only the three retained tables.

| Measurement | Saved CI | Focused local run |
|---|---:|---:|
| Case seconds | 47.30 | 34.07 |
| Harness SQL client calls | 222 | 73 |

These runs use different hosts. They are not a controlled speed comparison.
The new case executes nine CONVERT statements, compared with four before this
change. That added native conversion work is included in the case time. Do not
change production metadata probes or discard an old predicate to reduce it.
Fixture phase times are recorded separately in
`artifacts/charset-conversion-workflow-review/results.json`.

The selected run executed 8,750 of 20,880 mapped first-party lines.
The old measurements attribute coverage to a larger character-set group. The
selected run does not establish whole-group coverage parity or a loss in cases
which were not run. The SQL and predicate audit preserves this case's original
conditions.

All 17 selected Swift tests and 18 feature/migration tool tests passed.
Formatting, source-preservation, catalog and matrix checks passed. The matrix
retains 183 jobs, 1,545 catalog obligations and 182 coverage collections. Groups,
case ordering and profile exclusions are unchanged. No other profile, full suite,
benchmark or syntax suite ran locally.

Evidence:

- `artifacts/lab/20261104T000017Z-b1605622/result.json`
- `artifacts/charset-conversion-workflow-review/results.json`
- `artifacts/charset-conversion-workflow-review/state-results.json`
- `artifacts/charset-conversion-workflow-review/source-preservation.json`
- `artifacts/charset-conversion-workflow-review/matrix-comparison.json`
- `artifacts/charset-conversion-workflow-review/unit.log`

The [DEFAULT workflow results](BETA7_CHARSET_DEFAULTS_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed the reverse case, including source session checks and retained row states.
Next: review encoded Query SQL and identifier workflows. Keep the other areas and
full-matrix validation in the overall consolidation plan.
