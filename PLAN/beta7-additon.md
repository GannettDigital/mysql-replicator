# Beta.7 configuration file defaults

Source: the operator notes in the main checkout's `PLAN/beta7-additon.md`.
The original notes remain unchanged there.

## Requested behavior

Allow commands such as `mysql-replicator ctl status` without `--config`.
Provide a system configuration path, an environment override, and
`~/.mysql-replicator.yaml`. Use MySQL's system-before-user option ordering.

## Implementation

- `--config FILE.yaml` selects one file and overrides the environment selection.
- `MYSQL_REPLICATOR_CONFIG` selects one file when `--config` is absent.
- Without either selector, merge `/etc/mysql-replicator/apply.yaml`, then
  `~/.mysql-replicator.yaml`. User settings win. CLI overrides apply last.
- Merge maps by key. Replace arrays and scalars. Preserve explicit null.
- Fail on missing explicit files, invalid files, or no available default file.
- Select paths once per invocation. Reload uses the same paths and retains its
  existing stop-limit-only restrictions. Help and version remain read-free.
- Keep source-only `--source-config` commands explicit.

MySQL sources: [option-file order](https://dev.mysql.com/doc/refman/8.4/en/option-files.html),
[explicit file selection](https://dev.mysql.com/doc/refman/8.4/en/option-file-options.html),
and local `mysql-server/mysys/my_default.cc` (`init_default_directories`).
The environment variable name and YAML merge rules belong to this project.

## Checks

Status: implemented and locally tested on 2026-10-22.
All 30 focused tests pass. The five merge tests were rerun after corrections
to their test helper. Logs: `/tmp/beta7-config-defaults-tests.log` and
`/tmp/beta7-config-defaults-retry.log`.

Focused tests cover selection order, nested maps, arrays, null, CLI precedence,
missing and malformed files, fixed reload paths, size limits, help without file
access, and control commands against a real local socket. Full CI is deferred.
See [the command reference](../docs/COMMAND_LINE.md#configuration-files).
