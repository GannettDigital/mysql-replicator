# Release procedure

The first beta is `v0.1.0-beta.1` (Debian `0.1.0~beta.1-1`). Application versions
follow [SemVer](https://semver.org/); Debian's `~` keeps a beta older than its final
release. Config, state schema and codec ABI versions remain independent.

## Review and merge

The local work is organized as the following stack. Open each PR against the
preceding branch, so reviewers see one feature set at a time.

| Order | Branch | PR base | Scope |
| --- | --- | --- | --- |
| 1 | `beta/01-stack-ci` | `main` | CI for stacked PR bases |
| 2 | `beta/02-column-types` | `beta/01-stack-ci` | Composite primary keys and column types |
| 3 | `beta/03-source-reconnect` | `beta/02-column-types` | Source reconnect and rotation |
| 4 | `beta/04-target-reconnect` | `beta/03-source-reconnect` | Target reconnect, drain and diagnostics |
| 5 | `beta/05-ddl` | `beta/04-target-reconnect` | DDL parsing and compatibility policies |
| 6 | `beta/06-configuration` | `beta/05-ddl` | YAML, passwords, audited trigger skipping, demo grants |
| 7 | `beta/07-collation` | `beta/06-configuration` | Collation translation, rename and diagnostics |
| 8 | `beta/08-coverage` | `beta/07-collation` | Coverage and Periphery |
| 9 | `beta/09-release` | `beta/08-coverage` | Versioning, packages, service, docs and release workflow |

Merge from the bottom using **merge commits**, then retarget the next PR to main.
Wait for green CI after retargeting. Keeping ancestry avoids rebasing all remaining
branches; squash/rebase merges would require rebuilding the remaining stack.
The original local main contains the old unpublished history and must not be pushed
on top of the merged stack. Preserve any local edits before switching to the
merged upstream history. Do not delete the intermediate remote branches until
their dependent PRs have been retargeted.

## Qualify the release

1. Require green CI on the final **main commit**: unit tests, DDL catalog,
   package/archive installation checks, DML/DDL integration (normal and coverage),
   combined coverage and Periphery. Each intermediate PR also needs CI; local
   final-tree tests do not substitute for those branch checks.
2. Review `docs/releases/0.1.0-beta.1.md`, the install guide and the dependency
   notices/inventory in the assets. The notice collector preserves resolved source
   notices and toolchain copyright files; the SDK SBOM is an inventory, not proof
   that every SDK component's notice obligations have been reviewed.
3. On a representative deployment host, qualify service start, SIGTERM stop and
   clean resume with a prepared test target and the installed service account.
   Container installation tests do not run a real systemd boot or qualify the
   fleet's kernel/storage/CA configuration. Check pre-beta state permissions when
   upgrading from a root-run development deployment.
4. Confirm the source snapshot boundary and fail-stop/recovery limits are clear
   to beta users. There is no automatic repair of uncertain MyISAM writes.

## Prepare and publish

After merging and green main CI, create an annotated tag on that exact commit:

```sh
git tag -a v0.1.0-beta.1 <TESTED_MAIN_COMMIT> -m 'First beta'
```

The maintainer pushes the tag when ready. A tag push runs `release.yml`; it requires
main ancestry, matching `VERSION`, and a successful main CI run for that SHA. It
downloads the packages built and integration-tested by that successful CI run,
verifies their checksums, transfers those exact bytes between workflow jobs,
and creates a **draft prerelease**, not a published release. The workflow can be
rerun for a tag after CI finishes; it refuses to overwrite an existing release.
If CI artifacts have expired, rerun CI for the tagged commit before retrying.
The release workflow never substitutes a fresh, untested rebuild.
See [GitHub's release CLI](https://cli.github.com/manual/gh_release_create) for
`--verify-tag`, `--draft` and `--prerelease` behavior.

Review the draft assets and notes, verify downloaded checksums, and publish as a
prerelease (do not mark it latest stable). Never move a published tag or replace
its assets; use `0.1.0-beta.2` for corrections. The README's versioned download
links become live at publication. GitHub's source archive is additional to the
Linux binary artifacts. Signing/notarized macOS and Linux arm64 packages are
future release work.
