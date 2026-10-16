# Beta.6 review stack

The local release candidate is `0.1.0-beta.6`. It has ten review branches and one
release branch. No branch has been pushed. No PR number has been assigned.

## Base and preservation checks

- GitHub `main`: `957ba03f009e32f21b10bfd0d9060469688268eb`.
- Original beta.6 base: `0499da659b16d669e95a0607ec428e34714eaeb2`.
- Original beta.6 tip: `cef19ee870e1ce4797361745da277858288c7381`.
- The main tree equals the original base tree. There are no upstream file changes
  to port into this stack.
- All 80 beta.6 commits occur in one group each. Each group retains the exact
  tree at its original boundary. No feature was removed or reordered.
- The ten review branches contain eleven commits. The bulk formatting commit
  remains separate from the final functional fixes.
- The final feature tree equals the original beta.6 tip. The release branch adds
  version metadata, notes, this mapping and release instructions.

The [machine-readable mapping](../docs/releases/0.1.0-beta.6.stack.json) records
every source commit, new commit, tree and PR base. Existing `beta/6/*` branches
remain available. Branches 29 and 30 are abandoned experiments, not missing work;
the original plan records their replacements. Only commits reachable from the
final tip belong to this release.

## Review groups

Each branch targets the preceding branch. Only the first targets `main`.

| Order | Branch | Scope |
| --- | --- | --- |
| 1 | `beta/6-stack/01-types-and-encodings` | Charset/collation registry; native text bytes; floating-point and numeric attributes; ENUM/SET metadata; exact defaults; zero-width columns. |
| 2 | `beta/6-stack/02-identifiers-and-query-text` | Exact schema/cache keys; native name comparison; Unicode identifiers; Query-event encodings; saved table-name case settings. |
| 3 | `beta/6-stack/03-json-and-table-options` | JSON transport limits and YEAR translation; target-aware JSON defaults/indexes; FULLTEXT; table options; multi-table DROP and cross-schema RENAME. |
| 4 | `beta/6-stack/04-syntax-and-partitions` | MySQLSyntax target, unit tests and build layer; generated expressions; ALTER charset; spatial prefix indexes; CHECK compatibility; partition syntax, bounds and maintenance. |
| 5 | `beta/6-stack/05-stored-object-lifecycle` | Native CTAS and temporary-table restrictions; routine ALTER and conditional creation; multi-view DROP; journaled view/table renames. |
| 6 | `beta/6-stack/06-row-identity-and-foreign-keys` | Unique-key and full-row identity; keyless recovery records; FK cycles, disabled checks, missing parents, parent-key rules, generated columns and compound index changes. |
| 7 | `beta/6-stack/07-compound-ddl-and-comments` | Column/index/default dependencies; grouped constraints; table/column/partition renames; index visibility and SRID; native executable version comments; support limits and catalog updates. |
| 8 | `beta/6-stack/08-source-gtids` | Tagged capture, resume and replay; source GTID preservation; InnoDB/MyISAM execution; state migration, privilege checks and recovery limits. |
| 9 | `beta/6-stack/09-operations-and-progress` | Small support bundles; shared TLS policy; native include-filter precedence; durable operation/byte counters; replay ETA and live polling; CLI configuration overrides. |
| 10 | `beta/6-stack/10-style-and-boundary-checks` | Separate format pass and parallel lint check; exact UTF-8 filter identity; archive failure positions; complete source-map overrides. Retain the format pass and functional fixes as separate commits. |
| 11 | `beta/6-stack/11-release` | Version, release notes, stack mapping and release procedure |

The boundaries follow the existing dependency order. For example, foreign-key
and compound DDL changes use the earlier syntax and metadata work. Rebuilding a
stack by file category would split those dependencies and invalidate the tested
intermediate states. Tests, catalog entries and documentation stay with the
feature that introduced them.

## Validation and release work

Tree and ancestry checks validate the regrouping. They do not replace tests.
The [operational additions record](Beta.6.additions.md) lists the latest unit and
selected integration results. Those results apply to the original file trees.
No new full-catalog result is claimed for the regrouped commits.
Release metadata checks passed: 36 release-tool tests, SemVer/tag checks, Swift
format validation for the generated version file, helper syntax checks and
`git diff --check`. No binary was rebuilt for this grouping task.

Run normal PR checks on each branch. Put `ci-full` on branch 11. After all branches
merge, require successful full CI on the exact main commit before tagging.
The existing release workflow publishes the packages tested by that main run;
it does not rebuild them for the tag.

Do not add `ci-expanded-coverage` yet. Its current 339-shard plan exceeds GitHub's
256-job matrix limit. The ordinary full plan has 176 shards and remains usable.
Fixing the expanded plan is separate work; do not remove test assertions to fit it.

Before merge, record all eleven PR numbers in
`docs/releases/0.1.0-beta.6.plan.json`. The empty list deliberately prevents the
release script from running before the stack exists. See [the release procedure](../docs/RELEASING.md).
