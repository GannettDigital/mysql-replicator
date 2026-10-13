# Release procedure

The next release is `v0.1.0-beta.5` (Debian `0.1.0~beta.5-1`). Application versions
follow [SemVer](https://semver.org/); Debian's `~` keeps a beta older than its final
release. Config, state schema and codec ABI versions remain independent.
Only Linux x86_64 binaries and Linux/amd64 containers are distributed.

## Review and merge beta.5

This stack starts at upstream `main` commit `f881d70`. Each PR targets the
preceding branch. The feature commits remain unchanged.

| Order | Branch | Scope |
| --- | --- | --- |
| 1 | `beta/5/01-replay-operations` | Replay validation and support bundle diagnostics |
| 2 | `beta/5/02-test-selection` | Changed-file test selection for local use and CI |
| 3 | `beta/5/03-command-help` | Command-specific help with Swift Argument Parser |
| 4 | `beta/5/04-column-type-audit` | Type audit, configurable event limits and large SQL packets |
| 5 | `beta/5/05-bit-support` | BIT decoding, application and recovery |
| 6 | `beta/5/06-floating-point-support` | FLOAT/DOUBLE binary transport and defaults |
| 7 | `beta/5/07-json-support` | Typed JSON and partial row updates |
| 8 | `beta/5/08-release` | Version, release notes and installation guide |

The [release plan](releases/0.1.0-beta.5.plan.json) will list the required PRs.
Its PR list is empty until GitHub assigns the numbers. Release commands reject
an empty list. Do not merge the release PR with an empty plan.

The first PR targets `main`. The local `artifacts/release-stack-beta5/` directory
in the primary checkout contains the SHA manifest, PR descriptions and helpers:

```sh
bash artifacts/release-stack-beta5/push-branches.sh
bash artifacts/release-stack-beta5/open-prs.sh
bash artifacts/release-stack-beta5/push-branches.sh
```

The maintainer runs these commands. The first command checks the recorded branch
tips and pushes the stack without force. The second command creates draft PRs,
registers the native GitHub stack, and adds `ci-full` to the final PR. It also
records the assigned PR numbers in the release plan and commits that file on the
local release branch. The last command pushes that plan commit. None of these
commands pushes `main`, creates a tag, or publishes a release.

The helpers check branch tips and stop if the prepared stack has changed.
Base branches alone do not register a native GitHub stack. No GitHub write occurs
when the stack is prepared locally.

Review and merge from the bottom using GitHub's stack controls, waiting for green
checks. Merging an upper layer can also merge its unmerged predecessors. GitHub
may rebase/retarget remaining layers; fetch and synchronize local branches after
that operation before making more changes. The manifest checks deliberately
reject stale pushes. Do not manually retarget registered stack members or push
local `main` to bypass review. After all merges, update local `main` from upstream,
preserving unrelated edits. Every PR needs its own CI; local final-tree tests do
not replace checks on intermediate branches.

## Check the release candidate

Run the full suite on the final PR with `ci-full`. This includes the new large
value, BIT, FLOAT/DOUBLE and JSON cases on each applicable profile. Keep the
release-binary tests as the acceptance checks. Expanded coverage remains optional.

Start with the PR results. If a case fails, inspect its support bundle and saved
logs before deciding whether to reproduce it locally. See [JSON support and
remaining limits](../PLAN/JSON_SUPPORT.md). Do not describe the new type cases as
qualified until their integration checks pass.

## Qualify the release

1. Add `ci-full` to the final PR in the stack. Require its full checks to pass
   before merge. See [release testing](RELEASE_TESTING.md) for the trigger and evidence.
   Then require green CI on the final **main commit**, including unit/catalog checks,
   installer/package tests, production-image checks, full correctness and
   source/target reconnect for all four profiles and applicable capture variants,
   offline replay/control, native-reference DDL, recovery, demos, coverage and
   Periphery. Other PRs use [changed-file selection](PR_TEST_SELECTION.md).
   The labeled final PR and main use the same full suite; no additional qualification workflow is needed before tagging. CI packages the static binary once and
   checks integration uses those same bytes.
2. Review `docs/releases/0.1.0-beta.5.md`, the install guide and dependency notices.
   The SDK SBOM is an inventory, not proof that all license obligations were reviewed.
3. For a new deployment environment, qualify service/container start, acknowledged
   drain and clean resume on a representative host with persistent state and the
   actual service identity. Docker tests do not qualify a fleet's kernel, disks, systemd or Cloud SQL environment.
4. Confirm the organization allows GHCR package publication. The publishing job
   needs `packages: write`; repository linkage uses the OCI source label. Packages
   can initially be private even when the repository is public. An organization
   administrator must allow public visibility before we advertise anonymous pulls.

## Build and prepare

Local qualification (does not publish):

```sh
make release-artifacts
make release-image
```

Assets in `artifacts/release/` include:

- `mysql-replicator-0.1.0-beta.5-linux-x86_64.tar.gz`: standalone binary and notices.
- `mysql-replicator_0.1.0~beta.5-1_amd64.deb`: Debian package and systemd service.
- `mysql-replicator-0.1.0-beta.5-linux-x86_64-image.tar.gz`: tested `docker save`
  image, loadable without a registry as `mysql-replicator-release:0.1.0-beta.5`.
- `install.sh`, `apply.example.yaml`, `run.minimal.yaml`, `replay.minimal.yaml`,
  `LICENSE`, `NOTICE`, build evidence and
  `SHA256SUMS`, covering the build artifacts.
- `release-test-evidence.json`: added by CI after the full suite passes. It records
  the test run and a digest of the build checksum manifest.

After merging the **complete stack**, update your checkout to upstream `main`.
Keep the checkout clean. Install Python 3, Git, and `gh`. Use `gh auth login`
with a maintainer account that can read CI artifacts, push tags, and publish
releases. Use the same Git credentials for the HTTPS repository URL.

First, run the release check:

```sh
python3 tools/release_cut.py check
```

The script reads `VERSION` and the matching `docs/releases/VERSION.plan.json`.
It checks that every listed PR is merged and that HEAD is the current upstream
main commit. It requires successful main push CI on that exact commit. It downloads
the tested packages to a temporary directory, verifies full-suite evidence and
all asset checksums, then removes the temporary files. Allow space for the binary
archive, Debian package, and saved container image. The check does not change
Git refs or GitHub releases. It stops if the release tag already exists.

When the check passes and you are ready to create the draft, run:

```sh
python3 tools/release_cut.py tag
```

This command repeats the checks, creates an annotated tag, and pushes **only that
tag** to the repository in the release plan. It does not merge PRs or push branches.
If the push fails, the local tag remains. Inspect it before retrying the push;
the script does not delete or move tags. Do not run this command to repair an
existing draft. Inspect the release workflow instead.

For later releases, add a matching plan with the repository and required PR numbers.
The existing workflow and script accept prerelease versions only.

The maintainer runs the tag command when ready. `release.yml` requires main ancestry,
matching `VERSION`, and a successful main push CI run for that SHA. It downloads
that run's tested artifacts and `release-test-evidence`. It verifies the commit,
run attempt, full test scope, version and package checksums. It then creates a
**draft prerelease** with the evidence file.
It does not push an image or start another test suite at this point. If CI was
still running, rerun the release workflow on the tag when it finishes. Existing
drafts are not overwritten.
If CI artifacts have expired, rerun all jobs of the original main push CI run for
that exact commit. Do not substitute a manual smoke run or a local rebuild. Leave the release unpublished until ready.

## Publish binaries and the image

Wait for the **Prepare beta release** workflow to create the draft. Review its
notes and assets. From a clean checkout of the tagged commit, publish it with:

```sh
python3 tools/release_cut.py publish
```

This command checks the annotated remote tag, merged PRs, main ancestry, successful
CI, and the draft's evidence and asset checksums. It publishes the draft as a
prerelease without marking it latest stable. It stops if the release is already
public or if the evidence belongs to another CI attempt. Use a maintainer account.
Maintainer publication triggers the `release: published` job. A publication performed with a workflow's `GITHUB_TOKEN`
may not trigger another workflow, so do not replace this step with an automatic
publish using that token.

The publication job downloads the saved image from the release, verifies its
checksum, architecture, version and exact source revision, then loads and pushes
it to `ghcr.io/gannettdigital/mysql-replicator:0.1.0-beta.5`. It does not build
anything or publish `latest`. Existing image tags are not deliberately overwritten.
A failed GHCR step does not undo the published binary downloads; fix permissions
and rerun the failed job. If an image tag already exists, inspect it before retrying.

After the first push, set the linked package's visibility to **public** if allowed
by organization policy. Test the versioned archive download and installer without
GitHub credentials, and pull the GHCR image using a fresh unauthenticated Docker
configuration. Record the registry digest in the release notes for users who pin
images. Do not consider container publication complete until that pull works.
Also test the README's versionless installer command (requires `jq`). It selects
the most recently published release, including betas, then pins archive/checksum
downloads to that tag. GitHub's `/releases/latest` excludes prereleases, so the
README downloads the installer from `main` and the installer queries published
release metadata. Publishing a new release requires no README version edit.
If corporate policy prevents public GHCR, the saved image remains downloadable
from the public release and loadable with `docker load`; document that limitation.

Never move a published tag or replace its assets. Use a new SemVer prerelease for
corrections. GitHub's automatically generated source archives are additional to
the compiled Linux downloads. macOS and Linux ARM64 distribution remain deferred.

References: [GitHub releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases),
[GHCR access and visibility](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry),
[publishing on release events](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images).
