# Key row matching and ALTER TABLE: shared execution

Status: three workflows converted and verified locally. Keep the existing
keyless runner after measuring its trial. All four cases remain in the existing
keys-rows-gtids fixture. No case, fixture or job was removed or added.

## DBA-facing names and purpose

The former ddl-compat-grouped-constraints ID is now
`ddl-alter-table-columns-constraints-and-index-names`. The name describes these
source operations and replication checks:

- One ALTER TABLE adds a column and several constraints with ADD (...).
- UNIQUE indexes, and a foreign key on InnoDB, must match native MySQL.
- MySQL 5.7 ignores CHECK constraints. The target must preserve that behavior.
- A column named PRIMARY must get the same generated index names as native.
- DML must use the changed schema correctly after replicator restart and replay.

The case still requires a 5.7 source. The MyISAM SQL omits the FK clause.
Naming, catalog and selection checks verify the renamed ID. Requests for the
old ID report the replacement. SQL and source restrictions did not change.
The database runs below used the old label; no database run was repeated merely
for this rename. Use MySQL operation and replication behavior names for future
cases. A DBA should not need the implementation's internal terms to select one.

## Fixture and preserved boundaries

Each profile/variant group still starts its containers once. Keep the dedicated
GTID cases as the earlier review decided. Separate case IDs are not separate
container setups.

| Case | Original operations | Restart before operation | Replay stop after transaction | SQL selections |
|---|---:|---|---:|---:|
| ddl-compat-primary-key-parts | 11 | 3, 5, 8 | 4 | 10 |
| ddl-compat-unique-row-identity | 19 | 3, 8, 15 | 7 | 10 |
| ddl-compat-keyless-rows, unchanged runner | 27 | 3, 8, 13 | 7 | 10 |
| ddl-alter-table-columns-constraints-and-index-names | 13 | 5, 7, 11 | 6 | 6 |

Positions are one-based. Original statements and transaction counts stay first
and in the same order. Keyless replay still removes a duplicate after transaction
7, fails at transaction 8, checks engine-specific persistence, refuses blocked
resume and exercises the existing recovery path. That runner remains unchanged.
The ALTER case retains both its source-version restriction and engine branches.

## Adopted execution

KeyRowLifecycleWorkflows adapts the three definitions for execution and catalog
assertions. It does not change their original SQL or production code.

Batch ordinary operations between required observations. Check every original
predicate on the original live tables. Compare complete schemas and rows before
and after each restart, and at each predicate boundary. These checks must remain
live; a fresh copy alone cannot verify a restart-dependent condition.

For the other intermediate states, append source sequences that repeat each
prefix on distinct tables. A final source/native/target comparison checks those
retained states and the original final tables. Every earlier state is either
observed live or retained. Original expected values, projected fields and engine
adaptations remain unchanged. No extra write precedes an original transaction.

| Adopted case | Operations including retained states | Retained tables |
|---|---:|---:|
| Primary-key prefixes | 37 | 7 |
| Unique-key row matching | 93 | 9 |
| ALTER columns, constraints and index names | 31 | 8 |

The table map includes LIKE copies and RENAME destinations. Retained FK tables
use distinct constraint names. Cleanup drops children before parents. Original
tables must be absent after DROP. Saved-schema checks verify every retained
table. The unique-key identity query selects its original t and seq tables and
still requires two unique-key identities; its selected key must remain by_code.

Replay uses the existing reset, stop/resume and final-comparison helper. Cleanup
removes retained tables only after replay. The existing three live restarts stay
in each workflow. Guards reject changed operation counts, restart positions,
table creation/rename positions, transaction flags or named assertions until the
plan is reviewed again. Generic DDL phase guards and the ordinary index runner
remain unchanged. Other cases use an empty live-observation map.

## Measurement and the keyless exception

The source and saved-plan review used passing run 40454033524 at efb3458. The
first trial retained every prefix. All three forward cases passed, including
replay and the shared restart:
`artifacts/lab/20261107T022247Z-4d0e623c/result.json`.
Its keyless case took 109.54 seconds. Copying every prefix was too costly, and
original predicates needed live observations to retain their lifecycle context.

The refined trial retained only states between live observations. It passed
again, including the keyless failure/recovery path. The measurements below are
harness SQL client calls, not SQL statements issued by the applier.

| Case/profile | Saved calls | Trial calls | Trial seconds | Decision |
|---|---:|---:|---:|---|
| Prefix keys, 8.4 to 5.7 MyISAM | 179 | 125 | 41.38 | Adopt |
| Unique-key matching, 8.4 to 5.7 MyISAM | 302 | 201 | 51.18 | Adopt |
| Keyless rows, 8.4 to 5.7 MyISAM | 717 | 727 | 116.62 | Keep original runner |
| ALTER case, 5.7 to 8.4 InnoDB | 205 | 155 | 49.21 | Adopt |
| ALTER case, 5.7 to 5.7 MyISAM | 205 | 150 | 46.03 | Adopt |

The saved and local runs use different hardware and build contexts. These
numbers do not establish faster total CI time. They do show fewer client calls
for the three adopted workflows. The keyless trial added calls and removed no
container setup or job. It does not justify conversion. Keep its original
SQL, comparisons, restart and replay/recovery behavior. No keyless check was
removed. Unit checks confirm that the new helper does not select that case.

## Verification and evidence

All 18 focused Swift tests and 62 Python tests passed. They cover original SQL
and transaction order, both ALTER engine branches, retained prefixes, live
predicates and restart observations, table lifetimes, FK symbols and cleanup,
catalog naming, phase guards and selection/migration rules.

The adopted workflows passed these focused database runs with coverage and the
shared saved-schema restart:

- Forward prefix and unique-key cases, plus the subsequently withdrawn keyless
  trial: `artifacts/lab/20261107T032049Z-e62429de/result.json`.
- ALTER InnoDB branch: `artifacts/lab/20261107T034805Z-ac54176b/result.json`.
- ALTER MyISAM branch: `artifacts/lab/20261107T034832Z-704482f5/result.json`.

Code inputs remained unchanged throughout those runs. The final changes after
them withdraw the keyless helper and rename the ALTER catalog ID. Unit and
planning checks verify those decisions; they do not change the tested SQL of
the adopted workflows. Do not treat these local runs as a full current-tree
release result. Leave the remaining profiles and variants to CI.

Generated plans retain 183 jobs, 1,535 catalog obligations and 182 coverage
collections. Group memberships and job assignments are identical, apart from
the ALTER case rename in its six original selections. The migration requires
its original row and index-name predicates and retained-state checks. No new
BINLOG or no-preservation selections are added.

Evidence is under `artifacts/key-row-lifecycle-review/`: unit and integration
logs, before/after plans, `selection-results.json`, `first-results.json` and
`workflow-results.json`. Each fixture contains cases.json, assertion files,
SQL trace, saved state and code-coverage/combined/index.html. Coverage is for the
selected fixture; do not present it as one case's exclusive contribution.

Next: use one full instrumented CI run after the user pushes. Check failures and
coverage completeness first, then balance by measured fixture and test time.
Select the short PR case list last. Keep keyless, GTID, replay and recovery
boundaries where their distinct conditions require them.

## Keyless follow-up: comparison client costs

The initial analysis used the original successful
CI case, not the copied-table trial. The measurement report is complete, with no
missing coverage or failed shards. Comparison, JSON-oracle and MySQL client
helpers still match efb3458. The source workload and recovery sequence are also
unchanged.

| Profile | Case seconds | Harness SQL client calls | SQL client seconds | Remaining case seconds |
|---|---:|---:|---:|---:|
| 8.4 to 5.7 MyISAM | 82.01 | 717 | 56.50 | 25.52 |
| 5.7 to 5.7 InnoDB | 98.63 | 715 | 71.85 | 26.78 |
| 5.7 to 5.7 MyISAM | 99.91 | 716 | 72.99 | 26.91 |
| 5.7 to 8.4 InnoDB | 102.42 | 715 | 75.48 | 26.94 |

These client seconds include Docker execution, client startup, connection and
query execution. They are not measured MySQL server CPU or applier SQL time.
The remaining time includes process control, progress polling, replay and
recovery commands, file operations and other harness work. It is not all sleep.
The forward mean is 78.8 milliseconds per client call. This points to harness
round trips as a useful target, without proving their exact internal breakdown.

The original forward case performs 30 complete database comparisons across its
setup, 27 source operations and final replay result. Each role gets 30 metadata
batch calls: 90 calls and about 7.30 seconds in total. The much larger remainder
includes repeated raw-row and JSON-type reads. The native server is queried too;
this is verification cost, not extra application work on the replica.

### First change: batch the same comparison queries

For each role, the current comparison reads schema metadata, then reads each
JSON table separately. It issues another batch for type/value checks per JSON
table. It finally reads raw rows again, including the JSON tables whose output
will be replaced by the typed JSON results.

Keep every existing comparison and original operation boundary. Change only
how the reads are submitted:

1. Keep the fresh metadata query batch.
2. Read raw rows from all tables in one framed batch. Use that same result for
   ordinary row comparison and JSON-path discovery; do not fetch JSON rows twice.
3. Inspect all JSON cells across all tables in one bounded query batch. Keep
   the existing 32-query and 256 KiB limits, per-query identities and exact
   expected output widths. A limit can still require several client calls.

Keep server JSON_TYPE and scalar queries as the independent oracle. Do not
replace exact DECIMAL, temporal or opaque values with Foundation JSON numbers.
Keep DOUBLE bit handling, SQL NULL versus JSON null, duplicate multiplicity,
case/trailing-space bytes, signed zero and generated columns unchanged.

For this small fixture, the combined JSON inspection fits one batch per role.
A structural estimate across its 28 nonempty-schema snapshots gives 222 fewer
client calls: about 495 instead of 717. At the saved mean client duration, that
corresponds to roughly 17.5 seconds, or about 65 seconds instead of 82. This is
an estimate, not a measured improvement. It retains all source writes, original
live checks, three restarts and the transaction-7/8 failure/recovery sequence.
It creates no additional tables or replicated transactions.

### Later options

After measuring read batching, consider reading source, native and target in
parallel while source writes remain paused. Their comparisons are independent
after the catch-up barrier. Keep one result barrier before the next source write.
NativeHarness counters and LabSQLTrace currently have serial owners. They need
safe per-role collection and serial result merging before concurrent reads are
added. The current aggregates do not establish an exact parallel speedup.

Also consider caching only the row-query layout from validated server metadata. Fresh schema reads must still occur. On a DML-only
step, those metadata queries and the prepared raw-row queries could share one
batch. DDL and restart boundaries require a fresh layout. Unexpected schema
changes must fail comparison, not disappear behind cached metadata. This could
remove another metadata/raw-read separation on ordinary writes, but needs its
own proof and measurement.

The wait loop also calls source MySQL to evaluate GTID_SUBSET for progress.
The existing tested GTID-set implementation could do containment locally. The
forward trace groups 67 position/wait calls across source and native, costing
about 5.28 seconds; only part of this is replaceable subset work. Preserve native
catch-up checks and exact saved offsets. Do not claim all 67 calls can be removed.

A persistent read client per role could reduce more startup cost. Treat that as
a later change: session variables, sql_log_bin, GTID_NEXT, transaction state,
errors and reconnects must not leak between logical requests. Query batching
has a smaller scope and can be verified first.

### Validation scope

Start with the shared comparison/JSON batch helper unit tests and only the
original ddl-compat-keyless-rows case on the default forward profile. A controlled
before/after pair of that same case can compare calls and elapsed time on the
same host. This is a performance experiment on one case, not a smoke regression
set. Keep the original runner, assertions and source SQL fixed. Compare the
normalized schema/row results, JSON node types and values, restart outcomes,
blocked-state evidence, replay checkpoint and recovery outcome. Use support
bundles first on failure. Leave the other profiles and full suite to CI.

Detailed measurements and the structural estimate are in
`artifacts/keyless-cost-review/review.json`.

### Implemented read batching and local results

The shared comparison now uses LabComparisonRows to read each table once.
LabJSONComparison shares its inspection batches across all tables in that
comparison. Both helpers limit batches to 32 queries or 256 KiB of SQL. A larger
single query runs alone. Fresh metadata queries and the server JSON type/value
checks remain. A constant row marker keeps empty strings and duplicate empty
rows distinct from an empty result. Numeric query IDs keep byte-distinct table
names separate, including names with different Unicode representations.

The original keyless runner, 27 source operations, three deliberate restarts,
all original assertions and transaction-7/8 replay failure checks remain.
No replicated SQL, production applier code, case selection or job changes were
needed for this change.

Both runs used coverage builds on the same host and the default
mysql84-to-mysql57-myisam profile. These are case execution measurements. They
exclude image build and container setup time.

| Measurement | Before | After |
|---|---:|---:|
| Case seconds | 104.30 | 78.73 |
| Harness MySQL client calls | 684 | 462 |
| Client seconds | 68.89 | 44.87 |
| Schema-comparison calls | 90 | 90 |
| Separate JSON raw-row calls | 156 | 0 |
| Combined raw-row calls | 84 | 84 |
| JSON inspection calls | 147 | 81 |

The case took 24.5% less time in this pair of runs. The reduction of 222 client
calls matches the structural estimate. One pair does not establish the same
elapsed-time reduction on CI or on other profiles.

All 20 focused JSON, row-comparison and SQL-batch unit tests passed. Both
integration runs passed, including saved-schema restart and cleanup. Direct
comparison of their evidence confirmed:

- All 32 step files have identical SQL, assertions, normalized snapshots and
  results. This includes exact row bytes, duplicate multiplicity and JSON types.
- Replay stops after seven transactions, rejects the missing-row operation,
  refuses to resume from BLOCKED, and completes after the controlled reset.
- Both saved failure states contain BLOCKED, seven applied transactions,
  zero DONE rows and two PENDING rows for the active GTID.
- Final replication counters match. The combined runtime coverage sets contain
  the same 10,560 covered lines in both runs.

Before: `artifacts/lab/20261107T041555Z-d7c33cb4/result.json`.
After: `artifacts/lab/20261107T043000Z-51e779db/result.json`.
The comparison is saved in
`artifacts/keyless-read-batching/comparison.json`. Unit logs and the before/after
run logs are in the same directory. Source and test inputs stayed fixed during
each run. Leave the remaining profiles and full suite to GitHub Actions.
