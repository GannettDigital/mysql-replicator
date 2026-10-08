One way of assessing correctness (not performance) is to pull binlogs and operate in offline mode:

- have a mode to pull binlogs , either all available or from a certain position.
- then start applying binlog, from starting position (gtid) as we do now in config, but w/out continuing downloading a binlog, just work on binlog files available.

The purpose would be to see if we can apply binlog w/out errors w/out fully deploying the full infa -
For example, we clone an existing prod CloudSQL instance from an existing backup. Then in-place upgrade it to 8.0, and 8.4
assume it will retain last execiuted GTID.

We download binlogs from existing primary , and then start fron last exicuted GTID , targting clone upgraded to 8.4.
W/out caring for the speed, we can observe if binlogs can be cleanly applied w/out errors.

Ideally we would need a mode '<come up with a good name>' , in addition to 'run'

Also: we as the software will be operating on live customer data, in case of errors, we need to be able to do something like
"make support bundle" - cleaned up disagnostic info , sqlite state db , recent binlogs, etc as one file.
Assume that we cannot get access to live environment, but get copy of error output and support bundle file.

Could you look into approaching this?

## Agreed approach

Status: implementation planned for `fetch`, `replay`, and `support-bundle`.
Cloning, restoring, and upgrading databases are external operator activities,
not implementation or qualification tasks for the applier. Keep the original
use case above as context only.

Offline replay will use the same decoder, schema discovery, DDL policies, target
execution, SQLite journal, and recovery rules as live replication. Only the input
changes. Success means the captured workload applied without errors; proving data
equivalence additionally requires row/schema comparisons at a matching boundary.

### Commands and configuration

Use one YAML configuration file and a single `--config` option consistently:

```sh
mysql-replicator fetch --config offline.yaml
mysql-replicator replay --config offline.yaml --initialize
mysql-replicator support-bundle --config offline.yaml
```

Repeat `replay` without `--initialize` to resume a cleanly stopped run from SQLite.
Blocked or uncertain work retains the existing explicit recovery requirements.

The YAML file supplies the existing profile, source, target, state, and policy
settings, plus archive location, download selection/ending boundary, and support
bundle output/size settings. Exact new field names will be defined during
implementation. Do not add separate `--source-config`, `--archive`, or `--output`
options for these commands. The existing `--initialize` lifecycle flag remains.

Validate and resolve only what each command needs: `fetch` connects to the source;
`replay` reads the archive and connects to the target, with no source connection or
source password requirement; `support-bundle` collects local evidence without
requiring either database connection. Archive source identity/version/settings
replace live source preflight observations, with explicit provenance and checks.

### Baseline and archive contract

- Accept the operator-supplied complete source GTID baseline from configuration.
  Do not substitute a single maximum GTID for a set. Establishing that the
  baseline matches the target data is an external prerequisite; the applier does
  not inspect or verify any clone, restore, or upgrade procedure.
- Keep source progress in SQLite after replay starts. The reverse profile writes
  target-local GTIDs; the target's subsequent `gtid_executed` is not our source
  checkpoint. Keep the clone isolated from application writes during replay.
- Store ordinary binlog files with an ordered manifest: source identity/version,
  captured settings, file sizes/checksums, and explicit complete starting/ending
  boundaries. Accept files downloaded with `mysqlbinlog --raw` first, with
  supplied/validated provenance; add our downloader afterward.
- Download all available files or a selected range. Preserve format-description
  context and the complete transaction containing any requested start. Capture a
  finite end boundary so a busy source cannot make the qualification run endless.
- Check that the archive covers required history after the baseline. Missing or
  purged required history, corrupt files, and incomplete final transactions must
  not become a successful replay. Files are published as complete only after
  successful validation; interrupted downloads remain visibly incomplete.
- Skip already-covered GTIDs locally, before interpreting their row values using
  the clone's newer schema. Retain framing/checksum checks and required decoder
  context. Apply missing groups in physical order, including GTID-set holes.
- Preserve ordered schema discovery and DDL barriers for 5.7's limited metadata.
  Do not look up today's primary schema to interpret historical row events.
- Existing type/DDL/engine restrictions remain in force, including target trigger
  and foreign-key checks. Report archive/baseline errors separately from
  unsupported workload features and target execution failures.

The live download cache is disposable and is not an offline archive. Offline
files must survive process exit and remain usable without reconnecting to the
source. Keep the transport/file adapters separate from shared transaction apply
logic rather than creating another applier.

### Support bundles: troubleshoot first

For the initial version, provide one evidence bundle. Include sensitive workload
data when needed for diagnosis; do not require a separate sensitive-mode flag or
attempt general binlog anonymization. A sanitized-only bundle is deferred.

Include:

- Binary/build versions, replication profile, archive manifest, configured
  policies, limits, timings, counters, and recent failure/progress diagnostics.
- A consistent SQLite snapshot, including schema history, DDL intents, target
  failures, pending groups, and recovery audit records.
- The relevant relay/binlog data, prioritizing the failing/pending transactions
  and their format-description, table-map, and schema context. Include original
  SQL and row values where present; retain original source coordinates.
- An index of included files, checksums, and any omitted/truncated evidence with
  reasons. A size limit must not silently remove the context needed to interpret
  the failure. Full target data is not included, so every target-side failure is
  not necessarily reproducible from the bundle alone.

Exclude connection passwords, environment secret values, and TLS private keys
from configuration/connection evidence. Do not copy the original YAML verbatim.
SQL, row values, and database identifiers remain sensitive and are intentionally
not sanitized. Create the bundle locally with restricted permissions and label
it as containing customer data; do not upload it automatically.

Start with collection while the applier is stopped or blocked, taking the state
lock to prevent concurrent changes. Use SQLite's backup mechanism to include
committed WAL contents and capture relay evidence at the corresponding durable
boundary. Preserve any available unjournaled tail separately and label it. Do not
alter the original state, prune evidence, or perform recovery during collection.
Live coordinated collection can be a later extension.

### Implementation order and qualification

1. Add offline replay from existing raw binlogs, with a file input adapter and
   shared apply pipeline. Add command-specific configuration validation.
2. Extend the shared profile suite to compare live and offline application of the
   same workload: rows, schemas, GTID coverage, and saved checkpoints. Exercise
   multiple files/rotations, starts within files, excluded GTIDs and holes, clean
   resume, missing/corrupt files, truncated transactions, and DDL followed by DML.
   Replay must succeed with source access unavailable.
3. Add bounded downloading and archive publication/resume checks. Fetch should
   preserve structurally valid events even when semantic application is unsupported.
4. Add support bundles and tests for consistent snapshots, required failure
   context, size limits, secret exclusion, and unchanged original state.

The shared suite must run on both existing replication profiles. Test the three
commands and their data/state contracts. Cloud SQL clone/upgrade rehearsals are
out of scope; retain normal target preflight checks for flags, grants, and schema
compatibility without introducing upgrade-specific checks.

References reviewed:

- [MySQL raw binlog backups](https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog-backup.html)
- [Cloud SQL in-place upgrades](https://docs.cloud.google.com/sql/docs/mysql/upgrade-major-db-version-inplace)
- [Cloud SQL cloning](https://docs.cloud.google.com/sql/docs/mysql/clone-instance)
