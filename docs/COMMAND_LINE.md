# Command-line reference

Use `--help` after a command to show its options. Help does not read configuration
or connect to MySQL.

```sh
mysql-replicator --help
mysql-replicator replay --help
mysql-replicator ctl stop --help
mysql-replicator recovery resolve --help
```

`-h` also shows help. `mysql-replicator help replay` is an equivalent form.
`mysql-replicator --version` shows the release version, codec ABI, and capabilities.

## Commands

| Command | Purpose | Configuration |
|---|---|---|
| `config-help` | Show typed configuration help. Select a command or section. | None |
| `run` | Capture from a source and apply changes to a target. | `--config APPLY.yaml` |
| `fetch` | Download a finite source binlog range to a local archive. | `--config APPLY.yaml` |
| `replay` | Apply local raw binlogs without a source connection. | `--config APPLY.yaml` |
| `ctl status` | Read the state and progress of a running process. | `--config APPLY.yaml` |
| `ctl stop` | Request a graceful drain and wait for the process to stop. | `--config APPLY.yaml` |
| `ctl reload` | Reload the transaction and GTID stop limits. | `--config APPLY.yaml` |
| `support-bundle` | Collect local files for diagnosis while the applier is stopped. | `--config APPLY.yaml` |
| `skip GTID_SET` | Skip a captured failed GTID with no target write intents. | `--config APPLY.yaml` |
| `recovery inspect` | Read the saved records for uncertain writes. | `--config APPLY.yaml` |
| `recovery resolve ACTION` | Record a DBA resolution with `--gtids` and `--reason`. | `--config APPLY.yaml` |
| `inspect FILE` | Decode a local raw binlog file. | Optional `--schema HISTORY.json` metadata |
| `inspect --source-config SOURCE.yaml` | Inspect a live source stream without a durable checkpoint. | Source-only YAML |
| `inspect-relay FILE` | Decode a local relay file. | None |
| `blackhole --source-config SOURCE.yaml` | Measure capture and decoding without target application. | Source-only YAML |

Put connection, profile, archive, and policy settings in YAML. There is no
command-line option for each YAML setting. Existing `--source-config` inspection
and benchmark commands remain available. Schema history JSON is metadata, not an
alternative configuration format.

`run` and `replay` accept `--initialize` to create new state from the configured
baseline. Omit it to resume saved state. `ctl` commands accept `--timeout SECONDS`
from 1 to 86400; the default is 60. Reload can change only
`source.stopAfterTransactions` and `source.stopAfterGTIDs`. It cannot replace the
saved checkpoint or reseed a running process.

Recovery actions are `mark-applied`, `retry`, and `skip`. Check the target and the
saved records before resolution. See [offline replay and recovery](OFFLINE_REPLAY.md).
A support bundle can contain sensitive SQL, rows, configuration, and logs. The
command does not upload it.

## Output and errors

Help and version output are plain text on stdout, with exit status 0. Application
commands retain their JSON records and diagnostics. Errors are JSON on stderr,
with exit status 1. Argument-error text includes a usage hint inside the JSON
`reason` field. The parser does not print a separate text error.

Unknown options, missing values, duplicate options, and invalid combinations fail
before command execution. Options can appear in a different order. For local
`inspect` transaction output, supply both `--transactions` and `--binlog-file`.
Do not combine a local file with `--source-config`.

## Test lab commands

`replicator-lab` uses the same argument parser as `mysql-replicator`. Run a lab
command from the repository root. Help works from any directory and does not
start Docker or connect to MySQL.

```sh
swift run replicator-lab --help
swift run replicator-lab test --help
swift run replicator-lab demo resolve --help
swift run replicator-lab benchmark --help
```

Use `replicator-lab help COMMAND` as an alternative to `COMMAND --help`.
Use `test --list` for the JSON inventory of profiles, families, cases, and
variants. Repeat `--case ID` to select more cases. `ddl-catalog report` also
accepts repeated `--evidence PATH` options. Options accept either `--name value`
or `--name=value`.

The parser preserves the existing lab commands and their execution code.
The benchmark help identifies options that apply only to a specific mode.
Invalid options and missing values fail before setup. Test selection and
benchmark limits use the existing validation code. Lab errors remain plain
text on stderr, with exit status 2. Help uses stdout and exit status 0.
See [the test lab guide](TEST_LAB.md) for commands and expected results.

See [status and statistics](OPERATIONS.md) for counter definitions.

## Configuration overrides

Configuration commands accept dotted option names from `apply.example.yaml`:

```sh
mysql-replicator run --config apply.yaml --source.port 3307 --target.preserveSourceGTIDs false
mysql-replicator replay --config replay.yaml --source.stopAfterGTIDs 'UUID:1-1000'
```

Precedence is defaults, then YAML, then CLI. Supply a value for booleans.
Use YAML flow syntax for arrays or maps: `--replicateWildDoTable '["app.%"]'`.
An array replaces the YAML array; `[]` clears it. `null` clears an optional value.
Use `--config.version` for the configuration version; `--version` shows the
program version. Duplicate options and parent/child overrides are errors.
The configuration file is still required for execution. `--help` shows command
syntax and options. Use `config-help` for configuration types, defaults, units,
allowed values, and YAML examples:

```sh
mysql-replicator config-help --command replay
mysql-replicator config-help --command replay --section target
mysql-replicator config-help --section source.stopAfterGTIDs
mysql-replicator config-help
```

Omit `--command` for the full reference. `--section` accepts a section or a dotted
setting name. This command needs no configuration file and makes no connections.
It writes plain text to stdout. An unknown command or setting reports
`argument_error` on stderr and exits with status `1`.

`required` means required within the containing section. Conditional requirements,
such as target TCP versus Unix socket settings, appear in the description.
`default: none` means no fixed default value. Descriptions explain generated paths
and other values selected at runtime. `null: allowed` means that YAML `null` uses
the default or leaves the setting unset. Example values do not form a complete
configuration and can require changes to related settings.

The reference includes settings read or validated by the selected command.
For replay, source connection fields remain part of the file schema, but replay
does not connect to the source. Recovery and skip also validate the apply
configuration without connecting to MySQL. `ctl` reads only `stateDirectory`.
Section headings such as `source` group the options. Use a child option, such as
`--source.port VALUE`, to change one setting. To replace a whole section, supply
a YAML map, for example `--source.start '{executedGTIDs: ""}'`.

`ctl reload` reads the file again and reapplies the original CLI overrides.
It still permits only the two source stop limits to change. Thus, a stop limit
set on the run/replay command line takes precedence over edits to that limit in
the file. Other setting changes require restart. Support bundles show the
redacted effective configuration. Password arguments can appear in the operating
system process list; a password environment variable avoids this exposure.

For `blackhole` and source inspection, use `--source.port` and other `source.*`
overrides even though their YAML file contains source settings at the root.
Fetch accepts source, archive and profile overrides. Support-bundle accepts
stateDirectory, archive and supportBundle overrides. Control commands accept only
`--stateDirectory` to locate the running process.
