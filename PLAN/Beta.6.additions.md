# Beta.6 operational additions

Status: implementation and focused checks are complete. Selected container checks
are in progress. Keep these branches local until the user requests publication.
The parent is `beta/6/70-tagged-gtids` (`dd9dd1d`).

| Branch | Change | Focused checks |
| --- | --- | --- |
| `beta/6/71-support-bundle-ranges` | Binlog byte excerpts, original offsets and omitted-range index | 7 bundle/configuration checks passed |
| `beta/6/72-shared-tls` | Shared source/target TLS validation and configuration, including source verify-ca | 17 TLS/configuration checks passed |
| `beta/6/73-include-table-filters` | Native wildcard include precedence; live/replay filter scope; saved filter identity | 126 filter, DDL, restart, recovery and configuration checks passed |
| `beta/6/74-durable-statistics` | Operation, event and byte totals saved with checkpoints | 460 apply checks passed |
| `beta/6/75-progress-estimates` | Offline replay estimates and separate live metadata polling | 78 estimate, GTID, archive, configuration and restart checks passed |
| `beta/6/76-cli-configuration-overrides` | Dotted CLI settings; CLI over YAML; reload retains overrides | 34 CLI, configuration and bundle checks passed |
| `beta/6/77-swift-format-check` | Separate format pass and parallel CI check | All 781 Swift unit tests, 49 standalone syntax tests and lint passed |

These test selections overlap. Python tooling checks passed 157 tests with two
skips. The updated required-check gate passed eight tests. Periphery found no
unused code. These results do not replace release checks on all supported cases.

## Design rules

- Bundles retain a file prefix and bytes around a pending group or checkpoint.
  A byte excerpt is diagnostic data, not a standalone replay file. The JSON index
  identifies original offsets and incomplete groups. Relay frames retain decoded
  transaction context. Keep original archives for further investigation.
- Includes take precedence over wildcard ignores, as in native MySQL. An include
  list is not an allow-list from which ignore rules subtract entries. State format
  13 pins both lists. Older binaries reject format 13.
- Source and target accept the same TLS policy. Disabled TLS stays disabled after
  reconnect. Verify-ca checks the explicit CA chain without requiring a DNS name.
- Extra durable counters begin at `sinceTransaction` when an old state upgrades.
  They count completed groups and acknowledged rows, not uncertain writes.
- Replay computes missing GTIDs by UUID, tag and interval. A single configured
  endpoint estimates work through that endpoint. The exact stop rule is unchanged.
  The estimate uses recent processed transactions per second. It includes filtered
  and skipped groups. Replay never opens a source connection.
- Live polling runs outside the apply path. It uses actual binlog sizes and saves
  observations in SQLite. Monitoring errors are visible but do not stop apply.
  Catch-up estimates account for observed source growth and mark stale samples.
- CLI values override YAML. Arrays replace, `[]` clears, and `null` clears optional
  settings. Reload reapplies the same overrides and retains existing reload limits.
- Formatting uses Swift 6.2.1. The initial format pass is separate from functional
  commits. CI runs lint without a project build, alongside Periphery and tests.

## Release checks still required

Run the full supported catalog on the final release build. Recheck performance
with GTID preservation both enabled and disabled on the applicable targets.
The expanded coverage plan still exceeds GitHub's single-matrix limit. The
separate CI issue is recorded in [beta.6.md](beta.6.md). No branch was pushed.
