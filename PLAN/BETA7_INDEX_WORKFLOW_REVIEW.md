# Review of geometry prefixes, JSON indexes and Full-Text Search

## Decision

The column-definition and conversion work is committed as `893a18f`.
Convert the three cases below to source batches and final observations. Keep
their case IDs, profile exclusions and current CI group. They already share
containers and the main applier. No new job or separate fixture per case is needed.

1. Geometry BTREE prefixes: retain the initial prefix and spatial values.
2. Generated JSON-column indexes: retain the initial lookup and LIKE copy before
   the final UPDATE. Preserve both STORED and VIRTUAL source-SQL branches.
3. Full-Text Search: retain search results before destructive changes and keep
   the four named migration assertions. Add a direct parser-name check.

Implement these as one reviewed set, with focused unit checks as each case is
converted. Then build once and validate the set in two selected profile fixtures.
This avoids a separate image build and container setup for each small case.
The validation scope is specified below. Implementation results follow the review.

## Names and scope

Use terms from the MySQL manuals when changing titles:

| Existing case ID | Proposed title | Scope |
|---|---|---|
| `ddl-compat-spatial-prefix-indexes` | Geometry BTREE prefix indexes | Ordinary nonspatial indexes on geometry bytes. This is not a SPATIAL index or bounding-box search test. |
| `ddl-compat-json-indexes` | Secondary indexes on generated columns derived from JSON | Generated columns derived from JSON, STORED/VIRTUAL forms, index maintenance and CREATE TABLE LIKE. This is not a general functional-index test. |
| `ddl-compat-fulltext` | Full-Text Search: index changes and ngram parser | Selected BOOLEAN MODE searches, index lifecycle, CREATE/ALTER parser selection and LIKE. It does not prove equal search results for all text, settings or plugins. |

MySQL distinguishes SPATIAL indexes from nonspatial indexes on spatial columns.
Use that distinction for the geometry case.
[CREATE INDEX](https://dev.mysql.com/doc/refman/8.4/en/create-index.html).
The 5.7 acceptance and 8.4 rejection are recorded in the project's native probes
and profile exclusions; do not infer 5.7 behavior from an 8.4 manual.
[Geometry prefix notes](SPATIAL_PREFIX_INDEXES.md).

The JSON case indexes generated columns extracted from a document. Keep this
separate from direct functional key parts and expression defaults.
[Secondary indexes and generated columns](https://dev.mysql.com/doc/refman/8.4/en/create-table-secondary-indexes.html).

MySQL permits `WITH PARSER ngram` in CREATE TABLE, ALTER TABLE and CREATE INDEX.
The case tests explicit CREATE, ALTER ADD and LIKE, with distinct input strings.
Retain those operations and their selected BOOLEAN MODE predicates.
[ngram Full-Text Parser](https://dev.mysql.com/doc/refman/8.4/en/fulltext-search-ngram.html).

## Baseline

Use successful full CI run `40454033524`, commit `efb3458`. The summary and report
are complete. All three source files are unchanged from that run, including the
prior FULLTEXT consolidation. The shared runner has since changed.

Each cell is **case seconds / harness SQL client calls**, for default SQL runs.

| Case | 8.4 → 5.7 MyISAM | 5.7 → 8.4 InnoDB | 5.7 → 5.7 InnoDB | 5.7 → 5.7 MyISAM |
|---|---:|---:|---:|---:|
| Geometry prefixes | Excluded | Excluded | 32.66 / 141 | 32.83 / 141 |
| Generated JSON indexes | 43.87 / 250 | 36.15 / 249 | 43.87 / 249 | 44.60 / 249 |
| Full-Text Search | 47.99 / 283 | 39.07 / 282 | 48.44 / 282 | 48.63 / 282 |

The three 5.7-to-5.7 MyISAM cases used 672 client calls. The reverse JSON/FULLTEXT
pair used 531 calls. These are harness calls, not target SQL statement counts.
Do not predict elapsed-time savings: retained prefixes add source operations.

Evidence:

- `artifacts/index-workflow-review/baseline.json`: cases and SQL costs by role.
- `artifacts/index-workflow-review/source-comparison.json`: unchanged source files.
- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.

Coverage is attributed to the complete table/column/index group, not each case.
It cannot establish that one of these assertions is redundant. The earlier
FULLTEXT migration retained its measured lines and named predicates; it did not
remove the per-statement waits or schema comparisons. See
[the earlier migration](BETA7_TEST_SUITE_CONSOLIDATION.md#slice-4--full-text-search).

## Geometry BTREE prefixes

Keep all eight original statements. Keep the two restarts: before the UPDATE to
POINT(3 4), and before INSERT into the LIKE copy. There is no offline replay.
The forward and reverse profiles remain excluded because an 8.4 source or target
rejects these prefixes. Do not rewrite this case as a SPATIAL index.

Add one retained table that executes the first two operations. Total: ten source
operations. The original sequence stays first. Put retained preparation in the
last phase, then run final checks.

| Original condition | Final observation |
|---|---|
| CREATE with prefix 32 and INSERT of point, line and NULL | Retained table: index name, BTREE type and SUB_PART=32; exact spatial bytes and NULL row. |
| UPDATE point after restart | Original ID 1 remains POINT(3 4). |
| DROP/ADD compound index with prefix 16 | Original and copy: index parts `(g(16),id)` in order; native/source/target metadata agree. |
| LIKE and following INSERT after restart | Copy contains ID 4, POINT(4 5), with the copied index definition. |
| DELETE line and replace NULL with point | Original contains IDs 1 and 3 with POINT(3 4) and POINT(0 0). |

Keep exact geometry byte comparison from the shared snapshot. WKT assertions
alone are not a replacement for that comparison. Preserve the initial LINESTRING
and NULL state on the retained table because later writes remove them.

## Indexes on generated columns derived from JSON

Keep all ten original statements and both restarts: before the JSON UPDATE to
`gamma`, and before DROP/ADD of the copied name index. There is no offline replay.
The default source SQL creates a STORED `name` column. The transactional-target
alternative creates it VIRTUAL. Both branches add the later `n` column STORED.
Do not flatten these branches into one definition.

Add two retained sets:

- One table executes operations 1–2. It retains the `beta` index lookup that the
  original DELETE would remove.
- A source table and its LIKE copy execute operations 1–8. Rename both qualified
  table identifiers consistently. They retain the complete copied rows before
  the final copy UPDATE changes `delta/40` to `final/50`.

The retained sets add ten statements, for twenty total. Keep the original ten
first and put retained preparation in the last phase.

| Original condition | Final observation |
|---|---|
| Initial name index lookup | `FORCE INDEX(by_name)` on the initial retained table returns `(2,beta)`. |
| JSON UPDATE maintains the name index | Original `t` still returns `(1,gamma)` through `by_name`. |
| ALTER adds generated numeric column/index; INSERT uses it | Original `t` returns `(4,40)` through `by_n`. |
| DELETE and INSERT SELECT into LIKE copy | Retained copy has `(1,gamma,30)`, `(3,NULL,NULL)`, `(4,delta,40)`. Compare full JSON values and definitions as well. |
| DROP/ADD copied index and later JSON UPDATE | Original copy returns `(4,final,50)` through `renamed_name`; old `by_name` is absent. |
| Engine-specific generated form | Check STORED/VIRTUAL metadata with the selected SQL branch, for original and copied definitions. |

Use the existing independent JSON value/type comparison in the shared snapshot.
Do not replace it with raw JSON text equality. Preserve the original forced-index
queries; do not claim EXPLAIN-plan coverage that the case does not collect.

Leave `json-target57-limits` and `json-target84-schema` unchanged. The former
expects BLOCKED before writes. The latter uses a preexisting enhanced 8.4 target,
isolated apply and offline replay. They have different setup and failure/restart
contracts; merging them into this positive writer is outside this conversion.

## Full-Text Search

The earlier consolidation added ngram CREATE/INSERT/UPDATE/DELETE to this case.
It still uses eighteen ordinary `step` calls. Convert those calls, not the
feature ownership or migration record. Keep both restarts: before the first
UPDATE, and before INSERT into the table built with ALTER ADD WITH PARSER.
There is no offline replay.

### Retained default-parser results

Keep the original eighteen operations first. Add four tables, each executing the
original `t` prefix through operations 2, 3, 7 and 8 respectively. They add twenty
source statements.

| Prefix | Final observation |
|---|---|
| 2: CREATE and INSERT | Multi-column FULLTEXT metadata still has NULL collation/prefix fields despite `title(2)` in the source SQL. `+quartz` matches ID 1. |
| 3: UPDATE | `+quartz` no longer matches the multi-column index. Both stored rows remain available for comparison. |
| 7: DROP/CREATE/RENAME index, then UPDATE | Body-only `ft_renamed` exists; `+quartz` matches ID 2. Keep the entire DROP/CREATE/RENAME prefix. |
| 8: DELETE | Body-only `ft_renamed` remains; `+quartz` matches zero rows. This table must not execute the following index DROP. |

The original `t` ends with ID 1 and no FULLTEXT index. Check that final state too.
The final comparison must not try MATCH on that table after its last index is
dropped; use the retained tables for those searches.

### Retained ngram results and migration IDs

The original ALTER-created `ngram` and LIKE `copy` tables retain their final
searches for ID 3. Keep them separate from the default-parser table. The project
recorded a native InnoDB deleted-document-ID problem when it replaced the last
FULLTEXT index after deletions. Reusing that table for ngram would reintroduce
the known fixture problem. See [the native observation](FULLTEXT_SUPPORT.md#native-search-observation-during-fixture-review).

For the explicit CREATE WITH PARSER portion, add three retained tables. They
execute the local ngram-created prefix of one, two and three operations. These
add six statements. Total case size becomes 44 operations.

Preserve these exact assertion IDs from `tools/test_case_migrations.json`:

| Assertion ID | Final evidence |
|---|---|
| `fulltext-ngram-create` | Retained empty CREATE table: FULLTEXT definition and selected parser. Its empty rows and complete schema also enter the final snapshot. |
| `fulltext-ngram-insert` | Two-row retained table: original predicate `COUNT(*)=1 AND MIN(id)=1` for `xyzzy`. |
| `fulltext-ngram-update` | Retained post-UPDATE table: original zero-match predicate for `xyzzy`, with row 2 still present in the snapshot. |
| `fulltext-ngram-delete` | Original final ngram-created table: zero-match predicate for `qqvvq`, with only the updated ID 1 remaining. |

Move these names from per-statement `assertionID` to final assertion records.
Do not leave them attached to steps inside a phase: the phase planner rejects
hidden per-statement assertions. Do not drop or rename them to make that check
pass. The migration test must still find all four result files with the same
case ID and reviewed SQL predicates.

### Direct parser-name check

The generic snapshot reads STATISTICS, which has no parser-plugin field. The
current whole-word searches can also match with the default parser. They do not,
by themselves, prove that the target retained `ngram`. The applier's own schema
checks are not a substitute for an independent harness assertion.

Add final SHOW CREATE observations for explicit CREATE WITH PARSER, ALTER ADD
WITH PARSER, and the LIKE copy. Check the parser on the named FULLTEXT index.
Collect these reads with the other final queries in one batch per role.

Use a small harness-side projection of the relevant SHOW CREATE clause. Accept
native quoting and executable-comment wrappers in metadata. Do not compare
whole SHOW CREATE strings across engines or reuse the applier's discovery parser
as the only oracle. Unit tests must reject missing/wrong parsers, a parser on a
different index, a matching phrase inside a quoted column literal, and malformed
output. Include the pinned 5.7 and 8.4 output forms; capture them during focused
runs if existing artifacts do not contain them. Preserve raw output in assertion
evidence for diagnosis.

This is an additional independent metadata check. Record it as such; do not
claim that the old generic snapshot already tested the parser name directly.

## Focused validation

Keep implementation edits separate by case for review. Do not build a new image
for each edit. After focused unit checks pass, build the host lab and one matching
coverage image through the lab wrapper in OrbStack. Then run:

| Profile | Selected cases | Reason |
|---|---|---|
| `mysql57-to-mysql57-myisam` | Geometry prefixes, generated JSON indexes, FULLTEXT | Geometry prefixes require both versions to be 5.7. The same fixture covers STORED generated indexes and MyISAM search behavior, with an InnoDB source. |
| `mysql57-to-mysql84-innodb` | Generated JSON indexes, FULLTEXT | Covers the VIRTUAL SQL branch and InnoDB target behavior. SHOW CREATE observations include both 5.7 and 8.4 output. Reuse the same image. |

Do not add an 8.4-to-5.7 local run merely to repeat the same STORED SQL branch.
No changed source operation is specific to 8.4. Leave that profile and 5.7-to-5.7
InnoDB to CI unless implementation finds a distinct path that needs a local test.

Required checks:

- Unit tests for original SQL order, retained prefixes, both JSON SQL branches,
  two restarts per case, final index metadata and result expectations.
- Final-observation validation and parser-projection tests, including wrong
  output. Keep the exact FULLTEXT migration assertion names and predicates.
- The focused FULLTEXT migration test, applicable migration/feature checks,
  DDL catalog check and matrix comparison. Do not run parser suites unless
  production syntax code or its test/build setup changes.
- All named final assertions, checkpoints, saved-schema restarts, one fixture
  per profile selection, cleanup and coverage export.
- Compare SQL counts and separate setup/test/export times. Keep group-level
  coverage scope clear. Inspect a support bundle before retrying an applier error.

The matrix stays at 183 jobs, 1,545 obligations and 182 runtime coverage
collections. Keep the separate negative/version-limit tests and the retired
`matrix-fulltext` selection rules unchanged.

## Next step

Implement this reviewed set, then run the two focused selections above. Keep
full CI for the later combined suite check. After these conversions pass, audit
remaining per-statement paths in the table/column group before moving to other
feature areas. The initial review ran no builds, tests or containers.

## Implementation

All three cases now use three source batches. Their two deliberate restarts
remain at the original statements. The original 8, 10 and 18 statements remain
first and in order. Retained tables bring the totals to 10, 20 and 44 statements.
The final query batch reads each retained result on source, native and target.
The shared snapshot compares complete schemas and rows. Cleanup follows the
saved-state checks. No case ID, profile exclusion or replay contract changed.

`NativeFulltextParser` reads the named FULLTEXT index from native SHOW CREATE
output. It does not call the applier's parser. It handles quoted identifiers,
quoted literals and executable-comment wrappers. Final assertion files retain
the raw SHOW CREATE output, index name and observed parser. The three parser
checks cover explicit CREATE, ALTER ADD and LIKE.

The four FULLTEXT migration assertion IDs remain. The catalog now includes
final-observation IDs as well as per-step IDs. Its migration check first detected
that the old catalog path omitted the moved assertions. The fixed catalog and
all 58 focused Swift tests pass. Eight migration tool tests and ten feature tool
tests also pass. The matrix has the same 183 job assignments, 1,545 obligations
and 182 runtime coverage collections.

Evidence before integration:

- `artifacts/index-workflow-unit.log`: focused Swift results.
- `artifacts/index-workflow-review/source-preservation.json`: original SQL order.
- `artifacts/index-workflow-review/before-matrix.json` and `after-matrix.json`:
  unchanged execution assignments. Catalog assertion lists now include the
  final checks.

## Focused integration results

Both selected runs passed in OrbStack. All 97 named integration assertions
passed. Each selection used one fixture, then completed the saved-schema
restart, cleanup and coverage export. All ten deliberate case restarts remain.
The four FULLTEXT migration assertion files are present in both selections.
Raw metadata confirms the same executable-comment parser form on pinned MySQL
5.7 and 8.4. The assertions read `ngram` on the named `ft` index for all roles.

| Profile | Case | Named assertions | Harness SQL calls: saved CI → local | Case seconds: saved CI / local |
|---|---|---:|---:|---:|
| 5.7 → 5.7 MyISAM | `ddl-compat-fulltext` | 24 | 282 → 49 | 48.63 / 27.45 |
| 5.7 → 5.7 MyISAM | `ddl-compat-spatial-prefix-indexes` | 13 | 141 → 50 | 32.83 / 25.33 |
| 5.7 → 5.7 MyISAM | `ddl-compat-json-indexes` | 18 | 249 → 82 | 44.60 / 31.10 |
| 5.7 → 8.4 InnoDB | `ddl-compat-fulltext` | 24 | 282 → 62 | 39.07 / 34.28 |
| 5.7 → 8.4 InnoDB | `ddl-compat-json-indexes` | 18 | 249 → 85 | 36.15 / 30.49 |

Harness SQL client calls fell from 1,203 to 328 across these five case executions.
These counts include setup, observations and wait polling. They are not applier
SQL statement counts. Local and CI hosts differ; the elapsed times are not a
controlled speed comparison.

The image's Swift application/test build took 216.19 s. Dependency layers were
cached. The second selection used `--skip-build` and verified the same image.
Neither run started a separate fixture for each case. Each case has three body
batches plus setup and cleanup: 15 source phases for MyISAM and ten for InnoDB.

| Phase | 5.7 → 5.7 MyISAM seconds | 5.7 → 8.4 InnoDB seconds |
|---|---:|---:|
| Setup total | 15.010 | 18.978 |
| Container startup (part of setup) | 12.424 | 16.764 |
| Database preparation (part of setup) | 2.190 | 1.943 |
| Coverage export | 12.826 | 5.121 |
| Cleanup | 10.856 | 10.892 |

The selected MyISAM cases reached 8,953 of 20,880 mapped Swift runtime lines.
The selected InnoDB cases reached 9,006 of 20,880. These are different profile
selections. The baseline coverage belongs to the full table/column/index group,
so these counts cannot prove a coverage gain or loss for the converted cases.
The preserved SQL, explicit predicates and retained row/schema comparisons
provide the assertion comparison for this change.

Evidence:

- `artifacts/index-workflow-review/myisam-results.json` and `reverse-results.json`.
- `artifacts/lab/20261029T200657Z-a06ef754/result.json`: three MyISAM cases.
- `artifacts/lab/20261029T202143Z-2566812f/result.json`: two InnoDB cases.
- Each fixture's `assertions/ddl-compat-fulltext/`: four migration result files
  and three raw SHOW CREATE parser observations.
- Each fixture's `fixture-lifecycle.json`, `sql-trace.jsonl` and
  `code-coverage/combined/coverage.json`.
- `artifacts/index-workflow-review/matrix-comparison.json`: unchanged assignments
  and exclusions.

This reviewed set is complete. The DDL catalog check and `git diff --check`
passed. No full suite or production parser suite was run.

## Remaining table/column/index work

A source review found six cases that still need an assertion map before another
batch conversion. This is a work list, not permission to remove their checks.

| Case | Current execution | Review requirement |
|---|---|---|
| `ddl-compat-generated` | Seven per-statement steps | Preserve initial NULL propagation, generated values before UPDATE, and the row retained after DELETE. Keep the three migration assertion IDs. |
| `ddl-compat-generated-expressions` | Seven source phases with intermediate comparisons | Retain expression values and NULL inputs before subsequent writes. Keep both restarts. |
| `ddl-compat-generated-dependencies` | Eighteen source phases with intermediate comparisons | Retain expression replacement, rename, DROP and stored/ordinary conversion states. Keep restart and replay boundaries. |
| `ddl-compat-column-swaps` | Thirteen source phases with intermediate comparisons | Retain column order and key identity after each swap. Preserve generated-expression changes, restarts and replay. |
| `ddl-compat-column-index-syntax` | Nine source phases with intermediate comparisons | Retain implicit key names, SERIAL values and dropped definitions. Preserve replay boundaries. |
| `ddl-compat-alter-column-keys` | Fourteen source phases with intermediate comparisons | Retain AUTO_INCREMENT settings and rebuilt keys before later changes. Preserve restart and replay boundaries. |

Next: review `ddl-compat-generated` together with `ddl-compat-generated-expressions`.
Map each predicate to a retained table before changing execution. The existing
JSON-index case does not replace these numeric-expression and NULL checks.
Use saved CI measurements for the baseline. That review needs no build or test.
Then select one applicable profile for the implementation check unless the
review identifies different SQL or engine behavior that needs a second profile.
Do not repeat the five index case executions recorded in this document merely
to review another case. Keep full CI for the combined suite check.
