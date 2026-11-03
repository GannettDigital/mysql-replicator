# Executable comments: workflow review

## Decision

Convert the three executable-comment cases with the existing source-phase and
final-observation helpers. Keep their IDs, group, profile exclusions and replay
paths. Keep original source SQL first and unchanged. Do not change parser or
production apply behavior in this slice.

| Case | Original operations / predicates | New operations | Body batches | Restarts before original operations | Replay stop |
|---|---|---:|---|---|---:|
| `ddl-compat-executable-comments` | 8 / 2 | 13 | 2, 3, 8 | 3, 6 | 2 |
| `ddl-compat-executable-comments-target-gate` | 4 / 1 | 4 | 1, 3 | 2 | 2 |
| `ddl-compat-executable-comments-source-gate` | 4 / 1 | 4 | 1, 3 | 2 | 2 |

Only the main case needs retained objects. Keep the target-version case's
role-specific table-comment checks outside the common same-result queries.
Keep all journal checks and all three replay stop/resume paths.

The initial review used saved evidence. Implementation results follow below.
The absent-definer conversion was committed as `f9abcbe`.

## Names and contract

Consult MySQL documentation before naming features. Use
[Comments](https://dev.mysql.com/doc/refman/8.4/en/comments.html), including its
executable-comment syntax and version-number rules. Use these case titles:

- **Executable comments: version numbers, quoted text and row changes**.
- **Executable comments: active on source, inactive on older target**.
- **Executable comments: inactive on source, ordinary comment in binlog**.

Keep the contract in [Executable version comments](EXECUTABLE_COMMENTS.md).
The target receives the original logged SQL. The applier must not extract a
comment's contents to force a lower target to execute them. Source-disabled
SQL arrives in the ordinary-comment form produced by MySQL. A newer target
must not activate it. Quoted text such as `'/*! keep */'` remains string data.

These tests check successful row/schema results and deliberate version-dependent
behavior. They do not replace syntax tests for malformed comments, exact patch
thresholds, five/six-digit version formats or all quoting modes. This conversion
changes no syntax code, so it does not require the separate syntax suite.

## Saved measurements and source audit

CI run `40454033524`, commit `efb3458`, has no failed or missing shards and no
missing coverage. At review time, the three case definitions and their shared
journal/version checks matched that commit. All eight applicable default runs
passed:

| Case | Profile | Case seconds | SQL trace calls |
|---|---|---:|---:|
| Main | mysql84-to-mysql57-myisam | 37.72 | 174 |
| Main | mysql57-to-mysql84-innodb | 37.21 | 173 |
| Main | mysql57-to-mysql57-innodb | 37.09 | 173 |
| Main | mysql57-to-mysql57-myisam | 35.17 | 173 |
| Target version | mysql84-to-mysql57-myisam | 22.76 | 95 |
| Source version | mysql57-to-mysql84-innodb | 22.13 | 90 |
| Source version | mysql57-to-mysql57-innodb | 23.25 | 90 |
| Source version | mysql57-to-mysql57-myisam | 21.97 | 90 |

Calls are harness mysql client invocations, not applier target statements.
Saved coverage belongs to the whole views/routines/temporary-table group.
It cannot establish per-case coverage or prove that these cases are redundant.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/executable-comment-workflow-review/baseline.json`: eight saved results.
- `artifacts/executable-comment-workflow-review/source-review.json`: original SQL,
  predicates, retained SQL, batches, restarts and replay stops.
- `artifacts/executable-comment-workflow-review/review.py`: reproducible source audit.

## Main case: retain the UPDATE result

Keep original operations 1–8 first, through DELETE of row 1. Then CREATE DATABASE
`executable_comment_results` with CHARACTER SET utf8mb4 COLLATE utf8mb4_bin.
Append original operations 1–4, replacing only `ddlcompat.t` with
`executable_comment_results.ec_after_update` in every qualified reference.

Keep the exact original comment wrappers and quoted literal bytes. The retained
sequence must include the wrapped CREATE, INSERT, versioned inline ADD and UPDATE.
Do not replace it with a plain CREATE containing the desired final columns.
The retained table ends before `last_col` is added and before row 1 is deleted.

The first old predicate now reads the retained table:

```sql
SELECT id,n,note,extra FROM executable_comment_results.ec_after_update;
```

It must return `1`, `4`, `/*! keep */`, `7`. Keep the second old predicate on
original `ddlcompat.t`; it must return `2`, `3`, `7`, `9`. Add explicit final
metadata checks that original `last_col` is BIGINT and that `future_col` is absent.
Compare base-table schemas and rows in both databases.

Use batches 1–2, 3–5, and 6–13. Keep restarts before original operations 3 and 6.
Preserve replay stop after original INSERT transaction two. Resume through all
13 source operations and repeat final observations. Cleanup drops only
`executable_comment_results`, after journal and replay checks. Leave the original
table for the shared saved-schema restart.

## Target-version case: preserve different expected comments

Keep its four source operations and the forward-only profile restriction.
Use batches of 1 and 3, with the restart before operation 2. The final row
predicate remains `1,3`. No retained object or cleanup operation is needed.

Keep the existing TABLE_COMMENT query and expectations on every role:

| Role | Expected TABLE_COMMENT |
|---|---|
| Source 8.4 | `source-only` |
| Native 8.4 | `source-only` |
| Target 5.7 | empty string |

Register the existing three-role check as a named live assertion with observed
and expected values per role. Keep the existing target-only post-replay query
as a separate named assertion requiring an empty string. Do not add client calls
or force these different values through a same-result final predicate. Do not
use storage engine as a substitute for role/version: native and target are both
MyISAM in this profile.

Retain all three source-version exclusions. Replay still stops after transaction
two, the wrapped ALTER which 5.7 acknowledges without a metadata change. Resume
through transaction four. A target no-op remains a completed source transaction.

## Source-version case: preserve the source's ordinary comment

Keep all four operations, its restart before operation 2 and the forward-profile
exclusion. Use batches of 1 and 3. The final row predicate remains `1,9`.
No retained object or cleanup operation is needed.

Keep the source's `/*!80000 , ADD future_col INT */` unchanged in submitted SQL.
Keep the logged ordinary-comment check in SQLite. Do not reconstruct executable
syntax from that logged form. Add an explicit final INFORMATION_SCHEMA query
requiring no `future_col` on any role. The generic schema comparison remains.

Replay stops after transaction two and resumes through transaction four.
The focused reverse fixture checks the important 5.7-source/8.4-target condition:
the newer target must not execute SQL which the source disabled.

## Journal selection

Preserve the existing predicates and expectations:

- Main and target-version cases: a DONE record with identical source/target SQL,
  `source_sql LIKE '%/*!%ALTER%'` and the `target-version-executable-comments`
  context marker. Keep the nonzero count condition.
- Source-version case: exactly one DONE record with identical source/target SQL
  and `source_sql LIKE '%/* 80000%'`.

The main pattern requires the comment opening before ALTER. It selects the
original wrapped ALTER at operation 6. The retained prefix has an inline
comment after ALTER; it does not add a match to that pattern. Do not claim that
the retained prefix inflates this count or increase the expected count.

Use captured source GTIDs to identify the original records explicitly: main
operation 6, target-version operation 2 and source-version operation 2. Keep the
existing SQL and context predicates in addition to the GTID condition. Require
one captured source GTID for each selected operation. Use the shared SQLite
literal formatter. This does not need extra SQL calls or exact comparison of
submitted text with source-rewritten text.

Unit tests must preserve the ordinary-comment pattern, wrapper ordering and
nonzero versus exact-one expectations. Evaluate query selection with a small
SQLite fixture or read-only saved state before integration. Do not remove the
shared check that all DDL intents are DONE.

## Replay, metadata and execution limits

Pass final observations and the case ID into all three existing replay calls.
Use an empty cleanup list for the two four-operation cases. Do not add a source
cleanup phase for them. Keep all original source transaction counts at one.
Do not force empty warnings for comment statements. Keep default engine selection
and both source- and target-version exclusions.

Verify exact GTID sets and source file offsets at stop and resume. Keep the
unreachable source address for offline replay. Preserve saved-schema restart
and fixture cleanup. Do not add new lifecycle tests or merge the three catalog
IDs. All three already share containers with their group in CI.

## Implementation and local validation

1. Convert the three cases with the existing phase/final-observation helpers.
   Preserve original SQL first, four old predicates, four live restart points,
   three replay paths and profile exclusions. Add named role-specific comment
   checks without extending the common final helper for this one condition.
2. Add focused lab unit tests for retained comment/literal bytes, reference
   replacement, batches, original predicates, exclusions, source transaction
   counts, no-op checkpoints, journal GTID selection and cleanup scope.
   Test the role-specific expected values and all new explicit metadata checks.
3. Run main and target-version cases together in one forward MyISAM/default/SQL
   fixture with coverage. Run only the source-version case in one reverse
   InnoDB/default/SQL fixture with coverage. Read a failed run's support bundle
   before a rerun. Do not rerun main on reverse just to repeat shared helpers.
4. Check raw metadata, DONE journal records, original GTID selection, replay
   stop/resume GTIDs and offsets, saved-schema restart and cleanup. Compare
   matrix and catalog selection. Record SQL calls, setup, case, coverage-export
   and cleanup times. Do not infer per-case coverage parity from group reports.

Focused commands:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-executable-comments --case ddl-compat-executable-comments-target-gate --coverage"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-executable-comments-source-gate --coverage"
```

No full suite, benchmark, syntax suite or other profile run is needed locally.
Keep all eight applicable profile/case selections for the later full CI run.
Then review temporary-table workflows. Keep final balancing and selection of
short PR tests for the later measured CI comparison.

## Implementation and focused results

The three cases passed the two planned default/SQL fixtures with coverage:
main and target-version together on forward MyISAM, then source-version alone
on reverse InnoDB. No production apply or syntax code changed. All 16 original
source operations remain first and unchanged within their cases. The main case
adds five retained-history operations. Body batches are 2/3/8, 1/3 and 1/3.

All 39 named assertions passed. They include the four old predicates, new
column metadata checks, four live restart points, all three replay paths,
original journal checks and role-specific TABLE_COMMENT results. There were
11 source phases across the two fixtures: seven body batches, three setup
batches and one retained-database cleanup batch.

| Case | Saved CI calls | Local calls | Saved CI seconds | Local seconds | Named assertions |
|---|---:|---:|---:|---:|---:|
| Main, forward MyISAM | 174 | 88 | 37.72 | 32.00 | 19 |
| Target version, forward MyISAM | 95 | 52 | 22.76 | 20.14 | 10 |
| Source version, reverse InnoDB | 90 | 48 | 22.13 | 21.13 | 10 |

SQL trace calls fell from 359 to 188 for these three selected executions.
Saved times came from CI; new times came from a local machine. They do not
establish a controlled speed comparison or a whole-group time reduction.

The retained UPDATE row kept the literal `/*! keep */` and value 7 in `extra`.
The original remaining row kept defaults 3, 7 and 9. Explicit metadata checks
confirmed BIGINT for `last_col` and no `future_col`. The forward target-version
check returned `source-only` on source/native and an empty comment on target.
The target comment remained empty after replay. On reverse, the logged
`/* 80000 ... */` ordinary comment remained unchanged in target SQL; no role
installed `future_col`.

Read-only SQLite checks confirmed one original journal record for each case,
selected by its captured source GTID. Source and target SQL matched and all DDL
intents were DONE. No active GTID remained. Synthetic SQLite queries had already
verified GTID isolation, wrapper ordering and rejection of changed target SQL
before integration.

All replay stops matched transaction two. Resume counts were 13, 4 and 4, with
exact source GTID sets and file offsets at both boundaries. Every replay used an
unreachable source. Repeated final queries, saved-schema restarts and fixture
cleanup passed. The main case saved one retained base-table schema and dropped
only its retained database. The two version-specific cases added no cleanup
source operation. Raw metadata confirmed InnoDB source tables and MyISAM
native/target tables on forward; all three roles used InnoDB on reverse.

| Fixture | Setup seconds | Container startup | Database setup | Coverage export | Cleanup |
|---|---:|---:|---:|---:|---:|
| Forward pair | 14.39 | 11.77 | 2.21 | 7.81 | 10.06 |
| Reverse source-version | 17.67 | 15.32 | 2.09 | 4.19 | 10.94 |

Image build time is separate. The reverse run reused the image and compiled no
sources. Combined runtime coverage within each fixture was 8,624/20,880 lines
(41.30%) on forward and 8,385/20,880 (40.16%) on reverse. Saved coverage belongs
to the larger stored-object group. It cannot establish per-case coverage parity.
The source/predicate audit preserves the original conditions.

All 18 selected Swift tests and 18 feature/migration tool tests passed.
Formatting, catalog and matrix checks passed. The matrix retains 183 jobs,
1,545 catalog obligations and 182 instrumented collections. Group selection,
profile exclusions and the eight applicable profile/case selections remain.
No other profile, full integration suite, benchmark or syntax suite ran.

Evidence:

- `artifacts/lab/20261103T201029Z-1a672bb4/result.json`
- `artifacts/lab/20261103T203053Z-5ef24a35/result.json`
- `artifacts/executable-comment-workflow-review/forward-results.json`
- `artifacts/executable-comment-workflow-review/reverse-results.json`
- `artifacts/executable-comment-workflow-review/forward-state-results.json`
- `artifacts/executable-comment-workflow-review/reverse-state-results.json`
- `artifacts/executable-comment-workflow-review/source-preservation.json`
- `artifacts/executable-comment-workflow-review/sqlite-query-check.json`
- `artifacts/executable-comment-workflow-review/matrix-comparison.json`
- `artifacts/executable-comment-workflow-review/unit.log`

The [temporary-table conversion and group audit](BETA7_TEMPORARY_TABLE_WORKFLOW_REVIEW.md#implementation-and-focused-results)
passed both focused fixtures: 43 named assertions, 5.7 cleanup, engine variants,
exact replay checkpoints, saved-schema restarts and cleanup. SQL calls fell from
438 in saved CI to 173 locally. All 11 group cases now use final observations.
Next: review character sets and collations. Full-matrix validation, final
balancing and selection of short PR tests remain later.
