# Beta.7 local test entry points and CI selection

Status: reviewed after benchmark commit `a39e23c`. Makefile and documentation
cleanup is complete. The shared group selector below is proposed work.

## Current result

The current full CI plan contains 187 groups and jobs, 2,039 catalog obligations,
and 186 integration coverage collections. Eight groups run the 10K benchmark:
four profiles with SQL and BINLOG transport. CI reports ratios above the limit
without failing for that reason. Data, checkpoint and process failures still fail.

This review generated the plan from the built lab catalog. It did not start
containers or run the full test suite. The saved plan is at
`artifacts/test-suite-consolidation/local-entrypoints/matrix.json`.

## Makefile cleanup

Removed these Make targets:

| Removed target | Current entry point |
| --- | --- |
| `integration-smoke` | Inspect the actual PR baseline with `make lab-plan ARGS="--selection pr --commands"`. The old three-case selection was not the PR baseline. |
| `reverse-correctness` | `make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness"` |
| `reverse-suite` | Use the shared recovery suite and a separate performance selection. |
| `native-ddl-suite` | `make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite native"` |
| `native-smoke`, `native-suite`, `live-suite` | Old reference experiments remain accessible through the lab CLI. They are not the current CI matrix. |

This change removes wrappers, not test implementations or assertions. Retain the
separate installation, upstream source, parser, unit, coverage and package checks.
`lab-plan PROFILE=...` now uses the requested profile. Its default still selects
all profiles. The `--selection pr` preset selects its own profiles and cannot be
combined with another profile filter.

## Gaps

1. CI has named groups such as `keys-rows-gtids`. Local commands accept suites,
   families and cases, but cannot select a CI group by name.
2. `lab-plan` combines cases by profile, variant and suite. It does not preserve
   the reviewed CI group boundaries. Its command builder has no transport or
   benchmark-policy selection. It is a catalog selection plan, not a full CI plan.
3. The changed-file selector uses complete CI groups for component changes.
   However, its local `full` path still emits older suite-wide SQL commands.
   These omit performance and supplemental BINLOG jobs. They also repeat the
   MyISAM recovery alias already included in correctness.
4. Local execution is sequential. CI uses one shared build and runs up to 16
   integration jobs in parallel. A local elapsed time is not a CI time estimate.
5. Documentation had old job counts, repeated-coverage descriptions and main
   branch behavior. These statements are corrected. Historical measurements
   remain marked as historical evidence.

The dependency resolver, applicability checks and complete-group component
selection are useful and should remain. Do not replace them with new case lists.

## Proposed implementation order

1. Use one plan builder for CI and local named-group selection. Keep
   `tools/ci_matrix.json` as the group policy. Add group-name, profile, variant
   and transport filters. Keep exclusions and dependency reasons in the plan.
2. Add a local list, plan and run interface for those groups. Reuse the CI
   command renderer. Preserve transport, coverage choice and benchmark ratio
   policy. A group must retain one shared fixture. Reject unknown names and
   incompatible filters before container setup.
3. Make changed-file `full` selection use that plan. Remove the old suite list.
   Keep the two PR baseline selections and exact-path component rules. Local
   and CI plans must select the same obligations and transport combinations.
4. Document one named group across all profiles, the same group on one profile,
   a specific case, both transports, and report-only benchmarks. Distinguish
   catalog case selection from exact CI group reproduction.
5. Check plan equality with offline tests. Compare local and CI cases, variants,
   transport and benchmark options. Use one focused local group only if runner
   execution changes. Leave the full matrix to GitHub Actions.

## Current commands

See [local test commands](../docs/TEST_LAB.md#local-test-commands). Today, use
families or explicit cases for local selection. Use `ci_lab.command()` with the
generated matrix to reproduce a CI group exactly. The CI `--run` path expects a
prepared Linux build bundle; it is not a general local launcher.

Do not treat `make test-selected ARGS="--full"` as the full CI matrix until
step 3 is complete.

## Validation

- All 30 remaining Make targets pass a command-generation check with `make -n`.
  This checks recipes, not the execution of their commands.
- `make lab-plan` produces valid JSON for one profile, all four profiles and the
  two-profile PR baseline. These checks used the built lab binary.
- The 11 lab-selection tests and 14 changed-file selection tests pass.
- Current full and component plans were generated without database containers.
- `git diff --check` passes. No integration or full CI run was started.
