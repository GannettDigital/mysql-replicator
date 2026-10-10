# Release procedure

The next release is `v0.1.0-beta.4` (Debian `0.1.0~beta.4-1`). Application versions
follow [SemVer](https://semver.org/); Debian's `~` keeps a beta older than its final
release. Config, state schema and codec ABI versions remain independent.
Only Linux x86_64 binaries and Linux/amd64 containers are distributed.

## Review and merge beta.4

This stack starts at upstream `main` commit `5d877f0`. It includes the 13 local
feature commits, CI measurement tools, and release preparation. Each PR targets
the preceding branch. The release PR is last. Existing feature commits remain
unchanged.

| Order | Branch | Scope |
| --- | --- | --- |
| 1 | `beta/4/01-mysql57-myisam` | MySQL 5.7 InnoDB to MySQL 5.7 MyISAM profile |
| 2 | `beta/4/02-apply-performance` | Autocommit, durable preparation queues, schema cache and timing |
| 3 | `beta/4/03-innodb-foreign-keys` | InnoDB foreign keys, validation and recovery evidence |
| 4 | `beta/4/04-connections-support` | Profile documentation, plaintext connections and automatic support bundles |
| 5 | `beta/4/05-mysql57-innodb` | MySQL 5.7 InnoDB to MySQL 5.7 InnoDB profile |
| 6 | `beta/4/06-ci-measurements` | Timing, profile coverage and isolated cold/warm build comparisons |
| 7 | `beta/4/07-release` | Version 0.1.0-beta.4, release notes and installation guide |

The first PR targets `main`. The local `artifacts/release-stack-beta4/` directory
contains the exact SHA manifest, PR descriptions, validation notes and helpers:

```sh
bash artifacts/release-stack-beta4/push-branches.sh
bash artifacts/release-stack-beta4/open-prs.sh
```

The maintainer runs these commands. The push helper checks the recorded upstream
and local branch tips, then pushes the seven branches atomically without force.
It never pushes `main` or tags. The PR helper checks the remote tips, creates or
reuses draft PRs, and registers their ordered numbers using the
[native GitHub stack API](https://docs.github.com/en/rest/pulls/stacks#create-a-pull-request-stack).
Base branches alone do not register a native stack. No publication occurs merely
by preparing local branches.

Review and merge from the bottom using GitHub's stack controls, waiting for green
checks. Merging an upper layer can also merge its unmerged predecessors. GitHub
may rebase/retarget remaining layers; fetch and synchronize local branches after
that operation before making more changes. The manifest checks deliberately
reject stale pushes. Do not manually retarget registered stack members or push
local `main` to bypass review. After all merges, update local `main` from upstream,
preserving unrelated edits. Every PR needs its own CI; local final-tree tests do
not replace checks on intermediate branches.

## Measure the release candidate

Use the final PR for the [CI measurement study](CI_MEASUREMENTS.md).
Collect the expanded four-profile report and at least two valid cold/warm pairs.
Keep the normal release-binary checks. Do not infer test redundancy from line
coverage alone. Record run links with the stack's validation notes.
These measurements guide later CI work. They do not add another release build.

## Qualify the release

1. Require green CI on the final **main commit**, including unit/catalog checks,
   installer/package tests, production-image checks, full correctness and
   source/target reconnect for all four profiles and applicable capture variants,
   offline replay/control, native-reference DDL, recovery, demos, coverage and
   Periphery. The same suite gates PRs and main; no additional qualification
   workflow is needed before tagging. CI packages the static binary once and
   checks integration uses those same bytes.
2. Review `docs/releases/0.1.0-beta.4.md`, the install guide and dependency notices.
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

- `mysql-replicator-0.1.0-beta.4-linux-x86_64.tar.gz`: standalone binary and notices.
- `mysql-replicator_0.1.0~beta.4-1_amd64.deb`: Debian package and systemd service.
- `mysql-replicator-0.1.0-beta.4-linux-x86_64-image.tar.gz`: tested `docker save`
  image, loadable without a registry as `mysql-replicator-release:0.1.0-beta.4`.
- `install.sh`, `apply.example.yaml`, `run.minimal.yaml`, `replay.minimal.yaml`,
  `LICENSE`, `NOTICE`, build evidence and
  `SHA256SUMS`, covering the downloadable artifacts.

After merging the **release PR** and obtaining green main CI, create an annotated
tag on that exact commit (not on the pre-merge local branch):

```sh
git tag -a v0.1.0-beta.4 <TESTED_MAIN_COMMIT> -m 'Fourth beta'
git push origin v0.1.0-beta.4
```

The maintainer pushes the tag when ready. `release.yml` requires main ancestry,
matching `VERSION`, and a successful main push CI run for that SHA. It downloads
that run's tested artifacts, verifies checksums and creates a **draft prerelease**.
It does not push an image or start another test suite at this point. If CI was
still running, rerun the release workflow on the tag when it finishes. Existing
drafts are not overwritten.
If CI artifacts have expired, regenerate CI evidence for that exact commit; never
substitute an untested local rebuild. Leave the release unpublished until ready.

## Publish binaries and the image

Review the draft notes and downloaded asset checksums. Publish the draft as a
prerelease with a maintainer account (the UI or `gh release edit --draft=false`),
without marking it latest stable. Maintainer publication triggers the
`release: published` job. A publication performed with a workflow's `GITHUB_TOKEN`
may not trigger another workflow, so do not replace this step with an automatic
publish using that token.

The publication job downloads the saved image from the release, verifies its
checksum, architecture, version and exact source revision, then loads and pushes
it to `ghcr.io/gannettdigital/mysql-replicator:0.1.0-beta.4`. It does not build
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
