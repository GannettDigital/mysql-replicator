# Shared demo runbook

The demo uses the same profile, fixture and applier lifecycle as the automated
lab. Start with the [forward workbook](DEMO_WORKBOOK.md) for **8.4 → 5.7 MyISAM**
or the [reverse workbook](REVERSE_DEMO_WORKBOOK.md) for **5.7 → 8.4 InnoDB**.
Both include native same-version references and commands for four terminals.

## Prepare and run

From the repository root, with the [developer prerequisites](../CONTRIBUTING.md#prerequisites):

```sh
export PROFILE=mysql84-to-mysql57-myisam
make lab-demo ACTION=up
make lab-demo ACTION=start
make lab-demo ACTION=sql ARGS=examples/demo/01-success.sql
make lab-demo ACTION=compare
```

Choose `mysql57-to-mysql84-innodb` and
`examples/reverse-demo/01-success.sql` for the reverse workbook. Setup prints
container shell commands and the generated YAML path. `up` provisions an idle
applier container; replication only starts on `start` or a manual CLI launch.
`start` initializes once, then resumes clean STOPPED state from SQLite. It refuses
an active writer or unresolved BLOCKED state. Repeating `up` repairs a missing
shell using the pinned image; it does not reset data or rebuild a retained session.
Use `--skip-build` only after building the current checkout's demo image.

Passwords, TLS files and `/evidence/apply.yaml` are installed in the disposable
Docker volume. The host YAML is an evidence copy; editing it does not update the
installed configuration. Fixture accounts have broad privileges for demonstrations
and are not production provisioning examples. TLS certificates last seven days.
Recreate the session when its image, grants or certificates need updating. Shared
builds retain an image-ID tag (`mysql-replicator-lab-pinned`) so rebuilding another
profile does not remove an older session's image reference. These image caches
remain after `down`.

For a foreground launch inside the printed applier shell:

```sh
mysql-replicator run --config /evidence/apply.yaml --initialize
```

Omit `--initialize` when resuming. Do not also launch a detached writer. Foreground
output stays in that terminal; detached output is in `/evidence/applier.ndjson`
and `/evidence/applier.stderr`. `docker logs` shows the idle container, not these
exec sessions. `ACTION=status` reports process/container state, saved SQLite
progress/diagnostics and native replication status. `ACTION=stop` drains either
launch method without removing the shell. SIGINT/SIGTERM while idle or between
complete transactions also stop cleanly; uncertain/partial work can remain BLOCKED.

## Comparison and controlled failures

Pause source writes during `ACTION=compare`. It waits for the sampled boundary,
compares schema and rows on all three databases, and saves `comparison.json`.
It reads SQLite in the Docker volume after the completed boundary, without
interrupting a foreground or detached writer or creating a new checkpoint snapshot.
Comparison covers `demo.items` plus the preloaded `reverse_poc.items` and
`reverse_poc.aux`, with the expected profile-specific engine difference. It does
not compare arbitrary tables created in interactive experiments.

The forward workbook's `ACTION=fail` applies explicit InnoDB DDL that both MyISAM
replicas reject, verifies the fixed checkpoint and absence of following effects,
and writes `failure.json`. `ACTION=skip ARGS=GTID` permits only the captured failed
group with no write intents; it does not repair uncertain writes. The workbook
then exercises queued/fresh rows and MODIFY/index DDL. The native reference stays
blocked after the external applier's explicit skip.

The reverse profile provides `ACTION=inspect` and
`ACTION=resolve ARGS='retry --gtids GTID --reason "explanation"'` for audited
operator recovery. See [reverse replication](../docs/REVERSE_REPLICATION.md) for
the constraints. The demo is not a production clone/bootstrap or an automatic
crash-recovery tool.

## Evidence, coverage and cleanup

The current session manifest is `artifacts/demos/PROFILE/current.json`; its run
directory contains runtime metadata, config, comparisons and archived evidence.
`ACTION=down` drains the writer, exports coverage when enabled, archives SQLite
and relay files under `evidence-RUN_ID/`, then removes only that session's Docker
resources and manifest. Host artifacts remain. Do not copy live SQLite/WAL files
or delete only SQLite and replay the baseline against already changed targets.

Enable coverage when creating a fresh session:

```sh
make lab-demo ACTION=up ARGS=--coverage
# Run the workbook, then export and clean up:
make lab-demo ACTION=down
```

The image and coverage choice remain pinned across subsequent commands. Reports
are under `code-coverage/combined/`. The instrumented shell also records manual
CLI invocations. Coverage belongs to those actual executions; it is separate from
MySQL catalog qualification and should not be used for performance comparisons.

Old `artifacts/demo/` or `artifacts/reverse-demo/` sessions are not adopted. Archive
and remove one with `make lab-demo ACTION=legacy-down`, using its matching profile.
Recreate older shared sessions to obtain the current SQLite-equipped demo image.

## Automated rehearsal

```sh
make lab-list ARGS="--suite demo" | jq '.scenarios'
make lab-test ARGS="--suite demo --coverage"
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite demo --case demo-skip-and-resume"
```

The suite runs independent sessions under `artifacts/lab/`, never the retained
interactive session. Common cases check manual launch, 35 seconds of idle
heartbeats, database/table DDL and DML, exact counters, container repair, graceful
SIGINT/SIGTERM, saved GTID/file-position resume despite changed YAML, refusal of
reinitialization/concurrent writers and archived state. Forward-only cases cover
fail-stop, exact skip and MODIFY/index SQL. Reverse-only cases cover composite-key
transactions, rollback and audited retry. Case selection includes prerequisites;
unsupported cases are reported as `not_applicable`.

See the [test lab guide](../docs/TEST_LAB.md) for shared correctness, reconnect,
recovery and catalog evidence, and [coverage instructions](../CONTRIBUTING.md#code-coverage)
for combining explicitly selected unit and integration reports.
