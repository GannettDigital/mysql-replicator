# Temporary tables: workflow review

## Decision

Convert the two temporary-table cases with source phases and final observations.
Keep their IDs, order in the catalog, group and all four profiles. Preserve all
nine original source operations first within their cases and all seven old
query predicates. A source operation here can be a complete multi-statement
CREATE/use/DROP script. Do not split that script between sessions or phase writes.

| Case | Original operations / predicates | New operations | Body batches | Existing restart | Existing replay stop |
|---|---|---:|---|---|---|
| `ddl-compat-temporary` | 4 / 3 | 5 | 5 | None | None |
| `ddl-compat-temporary-create-select` | 5 / 4 | 12 | 3, 9 | Before original operation 4 | After transaction 3 |

Retain only the results which later writes remove. Keep the existing permanent
`ddlcompat.tmp` setup, explicit LIKE-template engines, 5.7 cleanup audit and
saved-schema restart. Do not add a replay or restart path to the first case.
Leave the separate permanent `create-select-contract` test unchanged.

The initial review used saved evidence. Implementation results follow below.
The executable-comment conversion was committed as `3ec125a`.

## Names and scope

Consult MySQL documentation before naming features. Use
[CREATE TEMPORARY TABLE](https://dev.mysql.com/doc/refman/8.4/en/create-temporary-table.html),
[CREATE TABLE ... SELECT](https://dev.mysql.com/doc/refman/8.4/en/create-table-select.html)
and [Replication and Temporary Tables](https://dev.mysql.com/doc/refman/8.4/en/replication-features-temptables.html).
Use these case titles:

- **Temporary tables: permanent row effects, name hiding and CREATE TABLE ... LIKE**.
- **CREATE TEMPORARY TABLE ... SELECT: permanent row effects and replay**.

Temporary tables belong to their session and can hide a permanent table with
the same name. In 8.4 ROW logging, only permanent-table effects are replicated.
The existing 5.7 apply policy also accepts the server's narrow
`DROP TEMPORARY TABLE IF EXISTS` cleanup form and records the skip reason.
Do not change that policy or generalize it to arbitrary DROP statements.

These cases do not select table filters. Keep existing filter tests and catalog
selection unchanged. Do not claim that these two cases alone verify filtered
temporary-table behavior. They also do not establish support for permanent
CREATE TABLE ... SELECT across incompatible versions or engines.

## Saved measurements and source audit

CI run `40454033524`, commit `efb3458`, has no failed or missing shards and no
missing coverage. At review time, both case definitions matched that commit.
All eight applicable default-profile runs passed:

| Case | Profile | Case seconds | SQL trace calls |
|---|---|---:|---:|
| Temporary/LIKE | mysql84-to-mysql57-myisam | 17.56 | 108 |
| Temporary/LIKE | mysql57-to-mysql84-innodb | 17.40 | 107 |
| Temporary/LIKE | mysql57-to-mysql57-innodb | 16.50 | 107 |
| Temporary/LIKE | mysql57-to-mysql57-myisam | 15.55 | 107 |
| Temporary SELECT | mysql84-to-mysql57-myisam | 24.74 | 112 |
| Temporary SELECT | mysql57-to-mysql84-innodb | 24.23 | 111 |
| Temporary SELECT | mysql57-to-mysql57-innodb | 24.56 | 111 |
| Temporary SELECT | mysql57-to-mysql57-myisam | 22.47 | 111 |

Calls are harness mysql client invocations. Saved coverage belongs to the whole
views/routines/temporary-table group. It cannot establish per-case coverage or
show that either case is redundant.

Evidence:

- `artifacts/ci-review/40454033524/measurements/summary.md` and `report.json`.
- `artifacts/temporary-table-workflow-review/baseline.json`: eight saved results.
- `artifacts/temporary-table-workflow-review/source-review.json`: original SQL,
  transactional SQL, predicates, retained scripts, batches and lifecycle checks.
- `artifacts/temporary-table-workflow-review/review.py`: reproducible source audit.

## Source session and transaction boundaries

Keep every original multi-statement string as one `LabSQLPhase.Write`. In
particular, CREATE TEMPORARY TABLE, temporary DML, permanent DML and DROP must
run in the same mysql client request. Preserve each USE statement. Never insert
BEGIN/COMMIT around these scripts or let the temporary table depend on a later
client request for its creation or removal.

The phase helper can share a client across operations because each original
script explicitly drops its temporary table. Preserve that DROP. Repeated
creation of `tmp` in the same batch must succeed without relying on disconnect
cleanup. Do not replace explicit DROP with session shutdown.

Keep declared `Step.transactions` values at one. On 8.4, retain the existing
check against those declarations. On 5.7, retain the comparison with the actual
source GTID delta. The current runner deliberately uses observed source counts
there; do not impose a new one-GTID-per-script requirement on 5.7 cleanup.

For replay stop three, verify the saved GTID/file offset against the third
captured transaction. Do not assume it equals the end of the third source script
if the 5.7 script emitted more than one logged group. Use captured groups or the
archived binlog when needed. Resume must reach the complete recorded source end.

## Temporary/LIKE: keep the permanent table and empty clone

Extract the inline case into a temporary-table workflow file if this improves
readability. Keep its reference in the same position in `DDLCompatibilityCases.cases`.
The original four operations remain first and unchanged, including both engine
variants of operation 3.

The case currently prepares permanent `ddlcompat.tmp` with row `99,99` before
its body begins. Keep both setup statements outside the body checkpoint interval.
Append them to this case's setup source batch after DROP/CREATE DATABASE. Do not
keep two extra per-statement waits or add them to the numbered body steps.
Other cases retain their ordinary two-operation setup.

Append one copy of original operation 3. Change only qualified destination
`ddlcompat.cloned` to `ddlcompat.tt_empty_clone`. Keep `USE ddlcompat`, temporary
name `tmp`, LIKE source `tmp`, explicit engine and DROP unchanged. It remains
one complete source script. No extra database or copy of operations 1–2 is needed.

Preserve all three old predicates:

| Predicate | Final target | Expected result |
|---|---|---|
| Permanent INSERT ... SELECT rows | Original `ddlcompat.t` | `1,7`; `2,8` |
| Clone is empty immediately after LIKE | Retained `ddlcompat.tt_empty_clone` | Count 0 |
| Following INSERT into clone | Original `ddlcompat.cloned` | `3,9` |

Add an explicit final query for `ddlcompat.tmp = 99,99`. It confirms that the
source's temporary table and the skipped cleanup did not remove or modify the
permanent table. Keep full schema/row comparison over `ddlcompat`.

For MyISAM target profiles, the source template and both permanent clones use
explicit MyISAM. For InnoDB target profiles, the transactional script uses
explicit InnoDB. Extend the existing raw-engine comparison exception from
`ddlcompat.cloned` to exactly the retained `ddlcompat.tt_empty_clone` pair.
Apply it only to source tables in MyISAM target profiles. Do not allow arbitrary
source MyISAM tables, exempt every LIKE result, or normalize away engine errors.

Use one five-operation body batch. Cleanup drops only `ddlcompat.tt_empty_clone`
after saved-state checks. Leave original `t`, `tmp` and `cloned` intact.

## Temporary SELECT: retain both earlier row sets

Keep original operations 1–5 first. Append two independent histories in the
same `ddlcompat` database:

| Original prefix | Retained base table | Required old row result |
|---|---|---|
| 1–3 | `tt_ctas_inserted` | `1,10`; `2,20`; `11,11`; `12,21` |
| 1–4 | `tt_ctas_updated` | `1,99`; `2,20`; `11,11`; `12,21` |
| Original final table | `t` | `1,99`; `11,11`; `12,21` |

Each history keeps the original permanent CREATE, initial INSERT and complete
temporary SELECT script. The second also keeps the temporary empty SELECT,
INSERT into `tmp`, UPDATE JOIN and explicit DROP. Rename both qualified and
unqualified references to the base `t`, including JOIN predicates and assignment
qualifiers. Preserve temporary name `tmp`, values, PRIMARY KEY clause, WHERE 0,
`id+10`, `n+1` and `id-98`. The source audit records the expected rewritten SQL.
Do not substitute final literal rows for these SELECT/JOIN operations.

Keep the original INFORMATION_SCHEMA predicate requiring no permanent `tmp`.
[INFORMATION_SCHEMA.TABLES](https://dev.mysql.com/doc/mysql-infoschema-excerpt/5.7/en/information-schema-tables-table.html)
does not list temporary tables. That predicate cannot by itself prove that the
session's temporary table was dropped. Keep it, but use script framing, explicit
DROP and successful same-session reuse to check temporary-table lifetime.

Use batches 1–3 and 4–12. Keep the restart before original operation 4 and the
existing replay stop after transaction three. Pass final observations and the
case ID to replay. Reset the two retained tables before replay, then repeat all
final predicates after resume. Cleanup drops only the retained pair in one DROP
TABLE statement. Leave original `ddlcompat.t` intact.

## Durable state and permanent CTAS contract

Keep the shared DONE-intent checks and saved-schema restart. Retain the existing
5.7 assertion that `ddl_skips` contains a positive count for reason
`row replication temporary-table cleanup`. Do not change it to a fixed count:
additional retained scripts can add cleanup records. Verify the permanent
`tmp` row still exists after cleanup processing.

Give the cleanup audit a named result with the observed count and reason.
If it moves closer to the case, preserve its source-version and selection guards
and run it after the applier has processed cleanup. A scoped case check may
supplement the existing fixture audit; do not silently drop the audit.

The native `create-select-contract()` method in `CreateSelectCases.swift` is
outside this conversion. Preserve its source/target rejection codes, native
atomic-DDL failure, BLOCKED state, unchanged checkpoint and empty write journals.
The review script confirms that method still matches saved CI. Do not run it
locally merely because the temporary SELECT case shares its file.

## Implementation and local validation

1. Convert the two cases and batch the permanent `tmp` preparation with setup.
   Preserve original scripts, ordering, seven predicates, declared transaction
   counts, engine variants and existing lifecycle boundaries.
2. Add focused lab unit tests for source-script framing, retained name bindings,
   old predicates, the permanent `tmp` sentinel, exact engine exceptions,
   cleanup ownership and no accidental BEGIN/COMMIT. Verify cleanup audit guards
   and the unchanged permanent CTAS contract through the source audit.
3. Run both cases together on forward MyISAM/default/SQL with coverage. Run both
   together on reverse InnoDB/default/SQL with coverage. The second fixture is
   required here for the 5.7 cleanup path, observed transaction counts and the
   InnoDB template variant. Keep one fixture per profile; no other profiles.
4. Inspect source phase GTID deltas, raw table engines, permanent sentinel rows,
   DONE intents, 5.7 cleanup audit, exact replay stop/resume positions,
   saved-schema restart and retained-table cleanup. Read a failed run's support
   bundle before a rerun. Compare matrix/catalog selection and record SQL calls,
   setup, case, coverage-export and cleanup times.

Focused commands:

```sh
make lab-test PROFILE=mysql84-to-mysql57-myisam ARGS="--suite correctness --case ddl-compat-temporary --case ddl-compat-temporary-create-select --coverage"
make lab-test PROFILE=mysql57-to-mysql84-innodb ARGS="--suite correctness --case ddl-compat-temporary --case ddl-compat-temporary-create-select --coverage"
```

No full suite, benchmark, syntax suite or permanent CTAS contract run is needed
locally. Keep all eight existing profile/case selections for full CI. After this
slice, audit completion of the stored-object/temporary-table group. Then return
to the remaining charset/collation, type/value and key/index reviews in the overall
plan. Keep final balancing and selection of short PR tests for the later CI run.

## Implementation and focused results

Both cases passed together in one forward MyISAM/default/SQL fixture and one
reverse InnoDB/default/SQL fixture, with coverage. All nine original source
operations remain first and unchanged within each case. All seven original
predicates remain. The permanent CTAS contract method remains byte-for-byte
unchanged from saved CI. No production apply or syntax code changed.

The two definitions now share `TemporaryTableWorkflowCases.swift`. Their catalog
order remains unchanged. Temporary/LIKE uses one five-operation body batch.
Temporary SELECT uses batches of three and nine. Every complete temporary-table
script stays in one source write and retains its explicit DROP. The permanent
`tmp` preparation now belongs to the four-operation LIKE setup batch, outside
the body checkpoint interval. Other case setup is unchanged.

All 43 named assertions passed: 21 on forward and 22 on reverse. The extra
reverse assertion records the 5.7 cleanup audit. Both original intermediate
SELECT/JOIN row sets, final DELETE rows, empty clone, following clone INSERT,
permanent `tmp = 99,99`, full schemas and saved-schema restarts passed. Retained
objects were removed after saved-state and replay checks. Original tables stayed.

| Case/profile | Saved CI calls | Local calls | Saved CI seconds | Local seconds | Named assertions |
|---|---:|---:|---:|---:|---:|
| Temporary SELECT, forward | 112 | 54 | 24.74 | 21.01 | 14 |
| Temporary/LIKE, forward | 108 | 32 | 17.56 | 9.73 | 7 |
| Temporary SELECT, reverse | 111 | 54 | 24.23 | 22.34 | 14 |
| Temporary/LIKE, reverse | 107 | 33 | 17.40 | 11.12 | 8 |

SQL trace calls fell from 438 to 173 across these four selected executions.
Old times came from CI and new times from a local machine. They do not establish
a controlled speed comparison or a new timing for the whole group.

### 5.7 transaction counts and replay position

The observed source counts confirm why scripts and transactions must remain
distinct. Temporary SELECT produced 12 transactions on 8.4 and 17 on 5.7 from
12 source operations. Temporary/LIKE produced five transactions on 8.4 and eight
on 5.7 from five operations. Source phase files retain every GTID delta. The lab
compared the actual source count with applied progress and kept the existing
5.7 behavior. It did not force one GTID per script.

The reverse saved state contained eight temporary-table cleanup skip records
across the selected workflows. The named case audit and existing fixture audit
both passed. The permanent same-name table and its `99,99` row survived. Raw
metadata confirmed explicit MyISAM source engines for exactly `cloned` and
`tt_empty_clone` on forward. Other forward source tables used InnoDB. Reverse
used the InnoDB template variant on all three servers.

Temporary SELECT replay still stopped after transaction three on both profiles.
On 5.7, the third source script also logs a later cleanup transaction; the stop
position is therefore before that script's end. Read-only checks selected the
third captured group, and verified its exact GTID set and file offset. Resume
reached 12 transactions on forward and 17 on reverse, at the exact captured
source end. Replay used an unreachable source address and repeated all final
queries. No replay or extra live restart was added to Temporary/LIKE.

Read-only SQLite checks confirmed STOPPED state, no active GTID, all body groups
APPLIED, all DDL intents DONE, exact file offsets and the retained table schemas.
The two fixtures each used seven source phases: three body batches, two setup
batches and two cleanup batches.

| Fixture | Setup seconds | Container startup | Database setup | Coverage export | Cleanup |
|---|---:|---:|---:|---:|---:|
| Forward pair | 14.34 | 11.77 | 2.18 | 4.67 | 10.99 |
| Reverse pair | 17.82 | 15.57 | 1.97 | 4.74 | 11.25 |

Image build time is separate. The reverse run reused the image without source
compilation. Combined runtime coverage was 8,293/20,880 lines (39.72%) on forward
and 8,548/20,880 (40.94%) on reverse. Saved coverage belongs to the larger group,
so it cannot establish per-case coverage parity. Source and predicate audits
preserve the original conditions.

All 19 selected Swift tests and 18 feature/migration tool tests passed.
Formatting, catalog and matrix checks passed. The matrix retains 183 jobs,
1,545 catalog obligations and 182 instrumented collections. All eight existing
profile/case selections remain. No other profile, full integration suite,
benchmark, syntax suite or permanent CTAS contract test ran for this conversion.

Evidence:

- `artifacts/lab/20261103T213051Z-40ccff58/result.json`
- `artifacts/lab/20261103T225618Z-3c8d412e/result.json`
- `artifacts/temporary-table-workflow-review/forward-results.json`
- `artifacts/temporary-table-workflow-review/reverse-results.json`
- `artifacts/temporary-table-workflow-review/forward-state-results.json`
- `artifacts/temporary-table-workflow-review/reverse-state-results.json`
- `artifacts/temporary-table-workflow-review/source-preservation.json`
- `artifacts/temporary-table-workflow-review/matrix-comparison.json`
- `artifacts/temporary-table-workflow-review/unit.log`

## Stored-object group: local completion audit

The catalog audit now finds final observations for all 11 cases in
`views-routines-temporary-tables`. It retains 37 applicable default/SQL case
selections and seven explicit profile exclusions. The preceding pilot, ALTER,
rename, conditional-routine, absent-definer and executable-comment results are
linked from the overall consolidation plan. Both temporary cases now have
focused results above. No remaining case in this group needs the old
per-statement comparison loop.

This is a local conversion and catalog audit. It does not replace a full group
or profile/variant CI run. Do not sum times from separate local fixtures and
present them as a measured whole-group time. Evidence:
`artifacts/temporary-table-workflow-review/group-completion.json`.

Next: review character-set and collation workflows against the saved SQL,
assertions, line sets and timings. Continue the remaining type/value and key/index
reviews in the overall plan. Keep full-matrix validation, final balancing and
selection of short PR tests for the later measured CI comparison.
