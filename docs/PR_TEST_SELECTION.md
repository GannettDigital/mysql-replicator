# PR test selection

Ordinary PR checks run unit tests, Periphery, and two integration jobs. Unit tests
and Periphery run in parallel with the integration build path. The integration
jobs share one instrumented image build, then run in parallel:

| Profile | Job area | Capture variant |
|---|---|---|
| `mysql84-to-mysql57-myisam` | `ddl-dml-policy-replay` | `default` |
| `mysql57-to-mysql84-innodb` | `ddl-dml-policy-replay` | `default` |

Both jobs run the same 11 named cases. This gives 22 profile/case obligations
and two integration coverage collections. `pr-smoke` remains the CI scope name.
The job area, logs, step summary, and matrix show the actual selection.

## Selected cases

| Section | Case ID | Main check |
|---|---|---|
| Database | `database-explicit` | Create a database with explicit compatible encoding. |
| DDL | `ddl-compat-types` | Create and use representative supported column types. |
| DDL | `ddl-compat-database` | Apply database and table lifecycle operations. |
| DML | `matrix-composite` | Apply changes with a composite primary key. |
| Index | `ddl-index-create` | Create an index and verify schema history, following DML, and binlog operations. |
| Trigger policy | `ddl-compat-skip-trigger` | Skip trigger definitions and apply their source row effects once. |
| Refusal | `reject-json` | Reject unsupported JSON DDL before target SQL. |
| Filters | `wild-ignore` | Exclude selected tables and apply included changes. |
| Basic apply | `positive` | Check DML, exact counters, completed intents, target identity, and independent binlog operations. |
| Offline | `offline-replay` | Fetch and replay archives, resume without source credentials, and inspect support-bundle contents. |
| Error policy | `live-skip-errors` | Check optional audit and counters. InnoDB rolls back a duplicate group and continues. MyISAM blocks after an uncertain write. |

The shared correctness runner also checks a clean checkpoint and saved-state
resume. These checks remain at their existing boundaries. PR tests use native
replication as a reference where the selected cases require it.

## Why this selection

The first nine cases ran together in PR #41 and PR #42. In PR #42, their shard
times were 178 seconds for MyISAM and 199 seconds for InnoDB. They exercise both
source versions, both target engines, decoding, SQL application, DDL, and policy.

Offline replay and live error skipping add two operational paths. Their measured
root-case times in PR #42 were about 20 seconds combined for MyISAM and 28 seconds
for InnoDB. Adding those times to the earlier groups gives estimates of about
198 and 228 seconds, before extra CI job overhead. Combining cases can change
their cost. Use the next PR run to validate these estimates.

The target is approximately five minutes per integration job with warm images.
Builds, unit tests, Periphery, and reporting also contribute to total PR feedback
time. This selection does not establish a five-minute workflow guarantee.

Coverage was collected per shard, not per case. Do not claim an exact coverage
gain for the two added cases until the new groups run with instrumentation.
The selection balances behavior checks and measured cost; it does not select
cases only to maximize Swift line coverage.

## Full-suite boundary

PR checks do not certify all data types, foreign-key behavior, collation mapping,
source/target reconnect, MyISAM crash recovery, operator demos, or same-version
profiles. Those remain in full CI. Unit coverage does not replace their database
behavior checks.

Full CI keeps all 718 catalog obligations and all release-binary selections.
Its two cross-version coverage supplements use this same explicit PR selection
so reports can compare full-suite coverage with the current PR baseline. The two
same-version smoke supplements keep their existing local smoke selection. Job
and collection counts remain unchanged.

## Change or inspect the selection

`pr_smoke` in [tools/ci_matrix.json](../tools/ci_matrix.json) contains the selected
case IDs and job area. The lab catalog defines each case and its prerequisites.
The CI planner resolves the IDs against the full catalog, adds prerequisites,
and preserves catalog order. Missing, inapplicable, duplicate, or cyclic selected
cases fail planning. Adding an unrelated full-suite case does not enlarge PR CI.

Generate the exact commands locally:

```sh
CI_SUITE=pr-smoke python3 tools/ci_lab.py --plan .build/debug/replicator-lab
python3 - <<'PY'
import json, shlex, sys
sys.path.insert(0, 'tools')
from ci_lab import command
for shard in json.load(open('artifacts/ci/matrix.json'))['include']:
    print(shlex.join(['.build/debug/replicator-lab', *command(shard)]))
PY
```

This requires a built lab binary. Generated commands use `--skip-build`; prepare
a matching coverage image first, or remove that flag from the first command.
The local `--tier smoke` convenience selection is separate from the explicit CI
policy. Use the generated commands to reproduce PR checks.

## Initial validation

Both complete selections passed locally with the matching release image: 11
catalog cases per profile, plus the shared checkpoint and saved-schema restart
checks. Evidence is in these ignored worktree paths:

- `artifacts/lab/20261012T055306Z-06b08861/result.json`: MyISAM target.
- `artifacts/lab/20261012T055309Z-6edce091/result.json`: InnoDB target.

The CI tool tests passed: 98 tests passed and two optional cache tests skipped.
Matrix comparison retained all 718 full-catalog keys, release selections, job
counts, and collection counts. Only the two cross-version coverage supplements
changed their selected cases. Instrumented CI timing and coverage for the new
groups remain to be measured.
