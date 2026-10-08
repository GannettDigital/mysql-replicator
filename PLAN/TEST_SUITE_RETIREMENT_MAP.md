# Legacy runner replacement map

This maps the forward DDL/DML assertions to the shared profile runner. It is a
review checklist, not a claim of complete MySQL compatibility. The historical
baseline contains 442 case executions across file-position/MINIMAL and
GTID-only/FULL variants. Duplicate execution of basic DML by two old commands
need not become duplicate fixtures, but its assertions and capture variants must
remain covered.

The [assessment](TEST_SUITE_RETIREMENT_ASSESSMENT.md) preserves earlier line-set
measurements. Before removal, compare successful legacy and shared runs on one
instrumented image with unchanged shipping sources. Keep catalog acceptance and
behavioral assertions separate from runtime line hits.

| Old case / workflow | Shared replacement | Preserved checks |
| --- | --- | --- |
| `positive` in both suites | `positive` | Four transactions/rows, exact final data, independent normalized binlogs on all three servers, durable position/GTIDs/intents/target UUID, direct YAML passwords; forward target GTID exclusion and three target reads |
| `matrix-<fixture>-<phase>` | `bootstrap-matrix-<fixture>-<phase>` under `bootstrap-matrix-<fixture>` | Equivalent unlogged snapshots, declared metadata overrides, fresh state per phase, independent SQL predicate, exact bytes across all roles, phase GTID count and durable checkpoint; zero-event phases are checked without inventing an apply invocation |
| `matrix-reject-*` | Same IDs, `dml-refusals` family | Expected refusal, exact target effects, BLOCKED/zero transactions/no position; generated mismatch retains pending row intent; native accepts the source-compatible row |
| Database positives | Same IDs, `database` family | Conditional-create warnings and retained defaults/data, exact transaction/DDL deltas and GTIDs, following writes, named catalog assertions |
| MODIFY/index positives | Same IDs, `indexes` family | Expected metadata/rows/warnings, following DML, counters and boundaries, schema history, independent normalized binlogs and named catalog assertions |
| `ddl-index-resume` | Same ID, `discovery` family | Initial indexed schema, resumed row and cumulative counters, all-role data, refusal after externally changing the saved target index |
| `ddl` plus 70 dependent steps | Same parent and child IDs, `ordered` family | Ordered SQL and warnings, conditional no-ops with populated matching/different definitions, same/cross-database LIKE/defaults, schema history, unchanged CREATE SQL, independent binlog operation order and named assertions |
| `wild-ignore*` | Same IDs, `filters` family | Exact included/excluded effects, independent binlogs, saved-filter resume, included-DDL refusal; prerequisite closure is explicit |
| `ddl-compat-*` positives | Same IDs, `ddl` family | Exact rows and metadata, object lifecycle, following writes, transaction/DDL deltas, saved state and no unfinished intents; database DROP retires old schemas |
| Collation cleanup/restart/policy refusal/collision | Same IDs, `collation` family | Translation audit and policy hash, table swap/LIKE/INSERT SELECT, restart with unchanged policy, refusal with changed/removed policy, NO PAD/PAD uniqueness collision |
| `ddl-compat-skip-trigger` bootstrapped workflow | `bootstrap-trigger-skip` inside `forward-failures` | Eight transactions, four row effects, five audited skips, no trigger/write intent on target, native trigger creation, final GTID and counters; the replicated-CREATE skip fixture remains additional coverage |
| Trigger/event policy, preexisting triggers, generated divergence | Same remaining child IDs inside `forward-failures` | Expected diagnostics and target effects, no following writes, pending generated-row evidence; source-trigger effects occur exactly once |
| Index limit/duplicate, DDL timeout/skip refusal, database/table permissions, unsupported defaults/types and missing LIKE | Same child IDs inside `forward-failures` | Restricted grants, actual target/native error codes, uncertain statement phase, durable pending intent and blocked following writes, persisted SQL/GTID/collation identity, CLI refusal to skip uncertain DDL |
| Extended GTID discovery/cache/fail-stop | Same 19 child IDs inside `myisam-recovery` | Multirow/key change and binlogs/read count; exact values; non-leading/composite PKs; 160 tables; schema reuse with explicit locks; external schema/key conflicts; refusal to initialize existing state; before-image/missing-row errors; native-channel exclusion; native 1837; target triggers; partial writes and all pending row intents |
| `batch-crash` and `batch-crash-resume` | Same IDs inside `myisam-recovery` | SIGKILL after a strict subset of 8,000 rows, all 8,000 row intents and group pending, no advanced checkpoint, ordinary resume refused without further writes |
| Source/target reconnect, drain and uncertain mutation (11 cases) | Same IDs in shared `lifecycle` | Same declared failure points on both profiles, profile-specific MyISAM persistence/InnoDB rollback, saved checkpoints and diagnostics, STOP/implicit rotation and capture variants |

## Applicability and boundaries

The forward refusal groups retain the historical 8.4-source/5.7-MyISAM contract.
A 5.7 source cannot supply 8.4 optional labels or 0900 collations. MyISAM partial
writes and InnoDB rollback need different expected effects. Explicit reasons in
the inventory prevent reverse passes from filling forward obligations. The
reverse rollback/inspection/audited-retry suite remains independently retained.

The recovery group is GTID-only, as in the original extended slice. Positional
capture remains exercised by basic/bootstrap/DDL and lifecycle workflows. The
ENUM/SET fixtures retain their explicit FULL-metadata overrides under the
otherwise MINIMAL historical variant.

Native-only skipping/reset between independent expected failures is disposable
fixture preparation. It is not automatic applier recovery. Each failed applier
state is preserved separately. The deliberately killed process cannot flush an
LLVM profile: its line coverage remains unknown even when the behavioral checks
pass. Rust decoder coverage is outside the Swift line report; FLOAT/JSON refusal
assertions still must pass.

Retirement must preserve the 68 previously accepted named catalog obligations
and leave the other 662 explicit and unresolved. Existing logical catalog suite
IDs may remain as contract identifiers after CLI removal; they must not retain
old runner dispatch roots. Native observation, reverse recovery, demo, protocol,
packaging and benchmark runners are outside this DDL/DML removal assessment.

## Validation status

Retirement is complete. Both full forward variants and reverse correctness passed,
as did shared forward lifecycle in all capture variants. The matched comparison
maps all 442 legacy executions to passing replacements and loses zero runtime
lines in either historical variant: 4,721 legacy versus 4,734 shared hits in the
forward union, on 5,858 mapped lines. Both catalog producers qualified the identical
68 named obligations; the other 662 remain unresolved.

After removing the old entry points, 340 Swift tests, 14 tooling tests and strict
Periphery passed. Shared integration, reverse database-resume and the direct
forward recovery command passed using the exact packaged executable. A fresh
instrumented ordered run passed 71 case results and its selected catalog bundle
qualified 22 assertions in one historical profile. All 55 shipping Swift source
hashes still match the full comparison. See the [assessment](TEST_SUITE_RETIREMENT_ASSESSMENT.md)
for artifact paths, checksums, historical failures and qualification limits.
