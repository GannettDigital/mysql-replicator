# Beta.6 CI failure corrections

Updated: 2026-10-17 UTC. This report covers the failures found in PRs 55–65.
The fixes are local. No CI jobs were cancelled or rerun, and no branches were
pushed during this work. The next CI run must check the updated stack.

## Build and unit checks

| First PR | Failure | Correction | Local check |
| --- | --- | --- | --- |
| 55 | DDL evidence test expects 730 obligations; this branch has 728 | Correct the assertion on the first affected branch | Six DDL evidence tests passed |
| 56 | Periphery reports an unused string-array comparison overload | Test exact UTF-8 bytes, order, length and empty arrays | Nine identifier tests passed |
| 64 | The pinned Swift image has no `make` | Call `swift format lint` directly | The exact command passed in the pinned Linux container |

Branch 3 removes the string-array overload. Its merge therefore removes the
new overload tests too. Branch 2 retains them. Later branches do not use that
removed overload.

The local Periphery check found no unused code, but its reused index contained
duplicate declarations from older builds. A clean CI Periphery run is still
required.

## SQL input in the harness

PR 55 run `38981724485` showed three related failures:

- The trigger fixture sent a mysql client `DELIMITER` command to the server.
- The native DDL fixture sent an empty statement between two semicolons as part
  of one server request.
- The demo logged a leading SQL comment with `CREATE TABLE`. The early stack
  branch rejected that event as a noncanonical control statement.

Later DDL jobs showed the same `DELIMITER` error in the stored-procedure case.
A local MySQL 8.4 probe confirmed the demo event difference. The saved probe is
`artifacts/ci-failures/demo-framing-probe.json`.

`LabSQLInput` now distinguishes a client script from a server SQL request. Both
paths preserve UTF-8 bytes through stdin. The client processes scripts and their
`DELIMITER` commands. A request keeps a compound routine body intact. The target
GTID reset is a separate request. The custom delimiter fits the mysql client's
15-byte limit.

The correction changes the trigger, routine, native DDL and demo callers.
It does not change the production SQL parser or transaction-boundary checks.

## Error-skip fixture

PR 60 run `38981745802`, job `117246844523`, expected an unsupported-ALTER skip
for `ALTER TABLE ... ENABLE KEYS`. Beta.6 supports that statement. The saved
report had the expected duplicate-key skip, but no DDL skip.

The fixture now uses a `GRANT` statement. Account administration is outside the
applier's scope and produces `ddl.unsupported_statement`. A locked test account
exists on each server so that the source and native replica accept the GRANT.

Each audit variant resets only its disposable target's GTID history before it
replays the same source groups. This avoids duplicate suppression when source
GTID preservation is enabled. The assertions still cover:

- Live and replay modes.
- Audited and counts-only skips.
- Skip counters after restart.
- InnoDB rollback before continuation.
- MyISAM refusal after a potentially partial write.

## Restricted fixture permissions

A local forward-failure run stopped during startup with MySQL error 1044.
Its support bundle showed no captured groups. The restricted test account lacked
access to `_mysql_replicator_gtid`, which source-GTID preservation uses on MyISAM.

The fixture now grants access to that scratch schema. It still denies CREATE on
the schemas used by the permission-failure tests.

## MyISAM reconnect fixture

PR 62 run `38981753753`, job `117248066385`, reported
`missed active group for source_batch`. Its support bundle showed the actual
cause: the generated SQL for the 8,000-row MyISAM group exceeded the target's
`max_allowed_packet`. No target mutation had been issued.

An initial correction raised the fixture's packet limit to 64 MiB. Local runs
then showed two more problems:

- Helper-function creation used the general SQL timeout instead of the configured
  DDL timeout. The applier now uses `ddlTimeoutSeconds` for that CREATE FUNCTION.
- The 8,000-row helper-function call exceeded the normal SQL execution timeout on
  local MySQL 5.7. The bundle retained the uncertain group and blocked replication.

The MyISAM lifecycle tests now use an explicit table lock and a 128-row group.
They first apply one row to load the table metadata. They then wait until the
helper-function request is issued against the locked table. Only then do they
interrupt capture or request a drain. They release the lock and check all rows,
GTIDs, counters and pending intents. This keeps the lifecycle assertion independent
of execution speed. InnoDB keeps its 8,000-row partial-progress test.

The 8,000-row MyISAM preserved-GTID execution timeout remains a separate limit
found by this investigation. This work does not claim that increasing
`max_allowed_packet` alone makes such groups succeed. Further work must measure
helper-function preparation and execution, then reduce the generated SQL or add
a suitable configurable execution deadline. The failed runs are retained below.

## Recovery and runtime-control fixtures

PR 62 run `38988605961` exposed two more test assumptions.

The MyISAM `multirow` application succeeded. Its final rows matched the expected
rows. The test still expected four client-side reads. With source GTID
preservation, the multi-row DELETE checks run inside the target stored function.
Only the two UPDATE checks use client-side reads. The assertion now uses the
configured preservation mode. Row and binlog comparisons remain in place.

The runtime-control test completed its first replay and resume. It then cleared
the target rows and started another replay with fresh SQLite state. It did not
clear the target GTID history. The applier correctly blocked a source GTID that
the target had already executed. The support bundle recorded that reason, but
the test reported a control-socket timeout.

The independent replay now resets the disposable target's GTID history before
it restores the seed rows. Resume cases retain their rows, GTIDs and SQLite
state. The status wait also detects an exited process and saves its logs. It
reports the applier diagnostic instead of waiting for a missing control socket.

Original CI evidence is retained under `artifacts/ci-failures/` in
`pr62-current-myisam` and `pr62-current-control`.

The wider local run then reached the older 8,000-row MyISAM crash test. Its
support bundle reported `MyISAM GTID group program exceeds target
max_allowed_packet`. SQLite retained one pending group; no target write was
issued. This is the same large-group limit described above.

For preserved source GTIDs, the crash test now applies one row to load metadata,
locks the target table, and submits a 128-row group. It waits until MySQL has
received the stored-function request, kills the writer, and releases the lock.
It checks the completed target rows and GTID, the unchanged SQLite checkpoint,
all pending row intents, and refusal to resume the unresolved group. The earlier
duplicate-key case still checks partial MyISAM persistence. The path without
GTID preservation retains its 8,000-row partial-write test.

## Validation

All listed checks passed. Container checks ran on the release branch as fixes were added. They used the
default capture variant. The native suite ran both engine-restriction variants.
Earlier successful checks were not repeated for unrelated later changes.

| Check | Profiles or scope | Result |
| --- | --- | --- |
| Focused unit tests | SQL input, account-statement skip, SQL batches, source-GTID execution | 11 passed |
| Format lint | All Swift sources and tests | Passed |
| Stored procedures and functions | All four profiles | Passed |
| Live and replay error skips | All four profiles; audited and counts-only | Passed |
| Forward failure sequence | 8.4 → 5.7 MyISAM | Passed |
| Native DDL suite | Forward reference, restricted and unrestricted engine variants | Passed |
| Demo success and its startup dependencies | 8.4 → 5.7 MyISAM | Passed |
| Source and target lifecycle | 8.4 → 5.7 MyISAM | 11 cases passed |
| Source and target lifecycle | 5.7 → 5.7 MyISAM | 11 cases passed |

Reports under `artifacts/lab/`:

- `20261017T000504Z-67a95bde/result.json`: routine checks on all four profiles and
  skip checks on the three 5.7-source profiles passed. This run failed the forward
  restricted-account setup before that grant was corrected.
- `20261017T001725Z-d98e2362/result.json`: the corrected forward failure sequence
  and both forward skip modes passed.
- `20261017T000646Z-7211cb78/result.json`: native DDL passed.
- `20261017T000648Z-865684c4/result.json`: selected demo checks passed.
- `20261017T004750Z-d20295a1/result.json`: all forward lifecycle cases passed.
- `20261017T004937Z-de3c68ef/result.json`: all 5.7-to-5.7 MyISAM lifecycle cases passed.

The large-group execution failures remain in
`20261017T004109Z-12c16065/` and `20261017T004258Z-6c706c8f/`, including support
bundles. They are not passing scale tests. The lifecycle test correction does
not close that execution-size and timeout investigation.

## PR 62 follow-up validation

The complete `failure-recovery-offline` area passed locally on all four profiles,
using the default variant and the full tier. This includes nested assertions
inside the MyISAM recovery and forward-failure cases.

| Profile | Passed cases | Report under `artifacts/lab/` |
| --- | ---: | --- |
| 5.7 → 5.7 InnoDB | 3 | `20261017T012040Z-97a33c1d/result.json` |
| 5.7 → 8.4 InnoDB | 3 | `20261017T012813Z-2ca0a7ed/result.json` |
| 5.7 → 5.7 MyISAM | 23 | `20261017T013800Z-a4bd9a45/result.json` |
| 8.4 → 5.7 MyISAM | 42 | `20261017T015738Z-d8d2a259/result.json` |

Both MyISAM crash cases recorded 129 target rows: one previously committed row
and the 128-row unresolved group. The target retained the group's source GTID.
SQLite retained all 128 pending row intents and its earlier checkpoint. Ordinary
restart refused replay and did not change the target rows.

The Swift lab build and format checks for the changed files passed. The InnoDB
runs preceded the final MyISAM-only crash-test correction. Other capture variants
remain for CI. The path without source-GTID preservation was not rerun locally.

The initial full MyISAM runs remain in `20261017T012423Z-20105a7b` and
`20261017T013044Z-134a7cb7`, including their large-group failure bundles. The
128-row crash tests do not close the large-group packet and execution limits.

## Saved evidence and push

Downloaded CI artifacts are under `artifacts/ci-failures/` in the release
worktree: `pr55-offline`, `pr55-native`, `pr55-demo`, `pr60-offline`, and
`pr62-reconnect`. Original support bundles are retained unchanged.

Merge commits carry the corrections through the local stack. Each branch retains
its published history. The existing push helper accepts the updated descendants:

```sh
bash artifacts/beta6-release-stack/push-branches.sh
```

These local checks do not replace the full CI matrix. The matrix includes other
variants and areas that were not rerun here.

## PR 59–61 assertion corrections

The next stack review found 13 failed jobs with four assertion problems.
Saved evidence is under `artifacts/ci-failures/stack-20261017/`.

| Case | Saved evidence | Correction |
| --- | --- | --- |
| `ddl-index-table-rename` | The following row used the current renamed schema. The DDL intent had no single `after_schema_id`; its transition list contained both names. | Compare the current schema with the journaled after-image and check the following row intents against that schema. |
| `ddl-compat-foreign-key-missing-parent` | The query matched two CREATE records, including one from an earlier FK case. | Filter DDL records by the current case's source GTID interval. |
| `ddl-compat-multi-table` | The query matched four complete DROP records across several cases. | Apply the same case GTID filter before checking the transition count. |
| `ddl-compat-keyless-rows` | Direct MyISAM execution recorded one row as DONE and one as PENDING. The group stayed pending and the checkpoint did not advance. | Check acknowledged and pending rows separately. InnoDB rollback and an unresolved preserved-GTID function keep both row intents pending. |

The case filter uses MySQL `GTID_SUBTRACT` and `GTID_SUBSET`. It does not parse
GTID intervals in the harness. The assertions still check exact counts. They do
not accept extra matching records from the current case.

The rename and keyless corrections retain row comparisons and checkpoint checks.
They do not change the applier's execution or durable-state behavior.

The first local grouped run passed the FK DDL cases and reached `ddl-index-like`.
Its schema and row checks passed, but a separate stale assertion expected SQLite
state format 12. Branch 9 introduced format 13 without updating that assertion.
The expected version is now 13 on branch 9 and its descendants. Earlier branches
retain their own expected state versions.

### Local results for the assertion corrections

The lab build, format checks for the changed Swift files, and `git diff --check`
passed. The following runs used the corrected state-version assertion:

| Check | Profile and variant | Result | Report under `artifacts/lab/` |
| --- | --- | --- | --- |
| Four index cases, FK replication and FK safety | 5.7 → 5.7 InnoDB, default | All six cases passed | `20261017T025559Z-d944d40f/result.json` |
| Keyless rows and multi-table DDL | 5.7 → 5.7 InnoDB, default | Both cases passed | `20261017T032644Z-cb8318d5/result.json` |
| Keyless rows and multi-table DDL | 5.7 → 5.7 MyISAM, default | Both cases passed | `20261017T032644Z-77448c82/result.json` |

The initial FK/index run, `20261017T022154Z-8ffced43`, passed all nine FK DDL
cases. It then failed the stale state-version assertion. The later six-case
index/FK run passed with the corrected version.

Two larger DDL runs completed all 45 selected cases each. Their final reports
failed the input check because the index state-version assertion changed while
they ran. These are not clean full-run results:

- `20261017T022446Z-42cd309d/result.json`: InnoDB; all 45 cases passed.
- `20261017T022446Z-16c7e683/result.json`: MyISAM; all 45 cases passed.

The final two-case runs above provide clean results for the corrected DDL cases.
The original larger-run evidence remains unchanged.

The lowercase-table run, `20261017T030455Z-2d7b5c26`, passed nine FK DDL cases
and four index cases. This includes missing-parent and table-rename assertions.
The run was then stopped at the user's request to limit local testing to changed
cases. Its final group result is incomplete. Its four fixture containers were
stopped, and its files were retained.

For subsequent test fixes, run only the changed cases locally. Leave the full
suite and other matrix variants to GitHub Actions. This rule is also in
`AGENTS.md`.

## Wider stack audit: failed and cancelled jobs

Reviewed the available checks for PRs 55–65 on 2026-10-17 UTC. The saved audit
contains 36 workflow runs, their jobs and artifact lists. Some jobs were still
running or queued at the last status read. This is an audit of recorded failures,
not a claim that every job has finished.

A final status read found 40 more failed or cancelled jobs. Their logs showed
the same DML timeouts, stale state-version and DDL assertions, offline positioning
error, and JSON replay reset error. Timing and release gates reported missing or
failed records. No new failure cause was found in those 40 logs. PRs 62–65 still
had running or queued jobs at that read; later failures are outside this snapshot.

Evidence is under `artifacts/ci-failures/stack-followup-20261017/` in the release
worktree. Support bundles were read before the affected tests were run locally.
The original bundles and logs remain unchanged.

### DML job timeouts

The DML jobs had 44–48 cases in one fixture. They reached the workflow's 45-minute
limit while cases were still passing. For example, PR 63 job `117288693905` was
cancelled after about 45 minutes during `matrix-fixedfloating`. PR 64 job
`117289207895` stopped during `matrix-generated`.

The CI policy now limits each DML group to eight cases. The generated normal
full plan grows from 176 to 226 jobs. It retains the same 2,085 obligations and
contains 60 DML jobs. Job names include the numbered DML area. Existing matrix
checks preserve case order and dependencies.

Missing measurement artifacts were a result of the cancelled test processes.
The final report and release gates then failed because required jobs were
incomplete. PR 55's `Debian Packaging & Integration Smoke` failure was such a
gate failure, not a Debian compilation error. Superseded runs with no jobs are
separate from tests cancelled at the timeout.

Expanded coverage is a separate limit. With the current catalog, its matrix
exceeds GitHub's 256-job limit both before and after this change. Normal full CI
fits the limit. Expanded coverage needs separate matrix groups before it can run
at this catalog size. This audit does not claim that expanded coverage works.

### New fixture corrections

| Failure | Evidence | Correction |
| --- | --- | --- |
| Offline DDL replay in the file-position variant | The command reported `offline replay requires GTID positioning`. No applier bundle was expected for this configuration error. | Select GTID positioning for offline replay. Keep file-position capture for the live phase and retain the saved starting GTIDs. |
| Encoded SQL with ENUM values | The bundle reported that ordered ENUM/SET label validation requires `binlog_row_metadata=FULL`. | Request FULL metadata for DDL cases that write ENUM/SET values. Restore the variant's metadata setting before other DDL cases. These cases do not claim MINIMAL ENUM/SET support. |
| Partition comparison with lowercase table names | The target metadata query returned each partition row twice after a second table was created. Data, columns and indexes matched. | Read PARTITIONS directly. Filter SQL views with the already-read base-table list. Compare exact name bytes and retain duplicate rows in the comparison. |
| JSON bootstrap replay with a fresh SQLite state | The target had already executed the source GTID. The bundle showed no issued target write and no applied transaction in the new state. | Reset the disposable target's GTID history to the saved starting boundary when a test restores its seed data for an independent replay. Apply the same correction to JSON YEAR, expression-index, spatial-metadata and large-value fixtures. |

The partition query issue was not reproduced in a separate local MySQL 8.4
probe. Both query forms returned four rows in that probe. The changed query
removes the subquery present in the CI failure. Focused lowercase-table tests
passed, but the original CI environment still needs to check this correction.

The target GTID reset helper is only for independent test experiments. Resume
checks keep their target rows, target GTIDs and SQLite state. The production
check for a target GTID that is missing from SQLite remains unchanged.

Other reviewed failures matched the assertion and state-version corrections
already recorded above. No additional production applier change was required
for the failures in this audit.

### Focused local checks

The lab build, format lint for changed files, and 26 CI matrix/runner unit tests
passed. Matrix generation retained all normal full-CI obligations. Only affected
cases ran locally; the full suite remains for GitHub Actions.

| Profile and variant | Cases | Result | Report under `artifacts/lab/` |
| --- | --- | --- | --- |
| 8.4 → 5.7 MyISAM, position-minimal | Executable comments, keyless rows, partition expressions, encoded SQL and charset conversion | Five passed | `20261017T043953Z-4ebc42d7/result.json` |
| 8.4 → 5.7 MyISAM, lowercase-tables | Partition expressions | Passed | `20261017T044129Z-17268db4/result.json` |
| 5.7 → 8.4 InnoDB, lowercase-tables | Ignored CHECK constraints and partition DDL | Both passed | `20261017T044424Z-d82ba0d6/result.json` |

The position-minimal selection also requested `ddl-compat-types`. Its existing
catalog rule marks that combination not applicable; it was not counted as a pass.

The first reverse lowercase run, `20261017T044129Z-7441f7e1`, failed during setup:
its target container was no longer running. No case had started and no support
bundle existed. The fixture logs were retained. A repeat of only those two cases
passed without a code change. The cause of that container stop was not confirmed.

The five GTID-reset cases passed on 5.7 → 8.4 InnoDB with the default variant:
JSON YEAR, target JSON schema, spatial metadata, expression dependencies, and
large values. Report: `20261017T045208Z-0101a01d/result.json`.

The large-value case also passed on 5.7 → 5.7 MyISAM with the default variant.
It checks that engine's separate blocked-resume path. Report:
`20261017T045605Z-c4a07aa3/result.json`.

Together, these runs contain 14 passing case executions. No full suite was run
locally for this audit. No GitHub workflow was rerun or cancelled. The fixes are
committed through the stack without rewriting published history.
