# PR test selection

Runtime PR checks run unit tests, Periphery, and two integration jobs. Unit tests
and Periphery run in parallel with the integration build path. The integration
jobs share one instrumented image build, then run in parallel:

| Profile | Job area | Capture variant |
|---|---|---|
| `mysql84-to-mysql57-myisam` | `ddl-dml-policy-replay` | `default` |
| `mysql57-to-mysql84-innodb` | `ddl-dml-policy-replay` | `default` |

Both jobs run the same 11 named cases. This gives 22 profile/case obligations
and two integration coverage collections. `pr-smoke` remains the CI scope name.
The job area, logs, step summary, and matrix show the actual selection.

## Select checks from changed files

[tools/test_selection.py](../tools/test_selection.py) contains the path rules for
local checks and PR CI. The selector combines all changed paths. The broadest
required scope wins.

| Changed files | Scope | Checks |
|---|---|---|
| Recognized documentation | `docs` | Python tool tests; no application build |
| Listed report tools, test selectors, and their tests | `tools` | Python tool tests; no application build |
| Runtime Swift/Rust, unit tests, example configuration, `Makefile`, or `.github/workflows/ci.yml` | `pr-smoke` | Python tests, Swift/Rust unit tests, catalog check, Periphery, and the two profile selections below |
| Harness, fixtures, dependency/package build inputs, other CI workflows, release tools, or unknown paths | `full` | Full existing CI suite |

The report-tool list is explicit. It includes coverage reports, PR coverage
comments, timing reports, and saved-result comparisons. A new file under `tools/`
does not get this exemption. Build scripts, coverage collection, test execution,
and release checks can change the tested binary or the test process. They need
full CI, except for the main `Makefile` and `ci.yml` entry points. Those two files
select the shorter two-profile PR checks. This verifies their build/test path
without selecting every correctness variant. Use `ci-full` when a change needs
all profiles, package checks, or all variants.

Changes to `tools/ci_scope.py`, `tools/test_selection.py`, and their tests select
Python checks. These tests verify path rules, Git diffs, CI outputs, overrides,
and the result gate. They do not need a database to check the selection policy.
The output's `selected_by` field lists the paths that set the final scope.

The CLI still starts capture and application from `main.swift`. Changes to this
file retain integration checks. Logging and timing changes inside runtime files
also retain those checks. Do not skip database tests from a PR title or a text
diff that appears to change only logging. A future command-help module can get a
narrower rule after it has its own tests and no runtime responsibilities.

CI compares the PR head with its merge base. A stacked PR uses its own base
branch. Deletions count. Renames count at both the old and new paths. CI reads the
Git diff without an API file-count limit. A missing base, an unreadable diff, or
an empty change list selects full checks.

`ci-full` and `ci-expanded-coverage` override path selection. Main pushes still
run full CI. Manual runs use their explicit suite input. The selection step saves
`test-selection.json` and lists the reason for each path in its job summary.
The required **Debian Packaging & Integration Smoke** check uses `always()` and
verifies all selected jobs. This follows GitHub guidance for
[required checks with job dependencies](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks). It accepts a skipped job only when the selector excluded that job.

Documentation and tool-only runs do not collect Swift coverage. Coverage and
measurement jobs skip those runs. Their absence is not a coverage decrease.

## Use the selector locally

Inspect a branch, including local edits, against its PR base:

```sh
make test-selection ARGS="--base origin/main" | jq
```

For a stacked branch, replace `origin/main` with the preceding branch. To select
checks for local edits only, use `--base HEAD`. Local selection includes staged,
unstaged, and untracked files. Add `--head HEAD` to inspect committed changes only.
The command does not fetch refs. Fetch the base first if it is not present.

Run the selected local commands:

```sh
make test-selected ARGS="--base HEAD"
```

Use `--commands` with `test-selection` to print copyable commands. Use `--full`
to force the full scope. JSON stays on stdout. Test output goes to stderr.
Execution stops at the first failure.

Local checks use existing commands and the same PR case IDs from
`tools/ci_matrix.json`. They run in sequence and use normal lab binaries.
They do not publish CI coverage or release evidence. CI retains parallel jobs,
instrumented collections, package checks, and the exact release-binary checks.
The full local selection runs all catalog suites and variants. Use CI to certify
the release packages.

## Selected cases

| Section | Case ID | Main check |
|---|---|---|
| Database | `database-explicit` | Create a database with explicit compatible encoding. |
| DDL | `ddl-compat-types` | Create and use representative supported column types. |
| DDL | `ddl-compat-database` | Apply database and table lifecycle operations. |
| DML | `matrix-composite` | Apply changes with a composite primary key. |
| Index | `ddl-index-create` | Create an index and verify schema history, following DML, and binlog operations. |
| Trigger policy | `ddl-compat-skip-trigger` | Skip trigger definitions and apply their source row effects once. |
| Refusal | `reject-geometry` | Reject unsupported spatial DDL before target SQL. |
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
cases fail planning. Adding an unrelated full-suite case does not change these
selected IDs. A harness change still selects full CI through the path rules.

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
