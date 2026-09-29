# Initial native-reference compatibility contract

Accepted direction from the user, 2026-09-29: use native GTID-to-MyISAM replication as the behavior reference for the initial Swift implementation. Swift is allowed to stop on the corresponding native-failing cases; exceeding native support is not an initial requirement.

The topology and settings stay unchanged: 8.4 InnoDB source with GTID ON/consistency ON, 8.4 native MyISAM reference and 5.7 Swift MyISAM target with OFF_PERMISSIVE/WARN. Native reference and Swift apply run on separate targets. The native failure does not justify disabling source GTIDs or starting native replication on the Swift-owned target.

## Scenario expectations

| Reference case | Initial Swift expectation |
| --- | --- |
| Native succeeds; scenario is in the declared Swift support matrix | Apply in order; match independently expected and native-observed rows and normalized logical binlog effects. |
| Native rejects a reproducible source operation/transaction | Swift may reject the corresponding case, persist a diagnostic and stop. This is an expected negative scenario, not a requirement to make native succeed. |
| Native succeeds but 5.7/Swift does not support the feature | Report explicit unsupported coverage; do not describe it as native-equivalent support. |
| Unknown failure, unrelated infrastructure error or inconsistent native result | Fail qualification or leave the case pending; an arbitrary nonzero exit is not a passing negative test. |

For the current corpus, separate autocommit DML is the positive reference; the original multi-statement source transaction producing native error 1837 is an accepted negative reference. These results describe the tested statement/transaction shapes, not every multi-row statement or all multi-statement transactions. Broader support is added through explicit fixtures and expected outcomes.

## Stop behavior

Swift must preserve raw source bytes, GTID/file/offset, the unsupported operation or transaction shape, diagnostic classification, schema context and any actual partial target progress. Persist BLOCKED, exit nonzero, do not advance the completed-transaction applied checkpoint through the rejected transaction, and do not apply later transactions. Restart must preserve the block; operator correction and explicit resume remain required. Source capture checkpoints may describe durably captured bytes but are never evidence of applied completion.

Because Swift assembles complete source transactions before applying them, reject a recognized unsupported shape before target mutation where possible. It need not reproduce native's partial MyISAM writes, premature GTID bookkeeping or numeric error 1837. If any writes have already occurred, accurately journal and expose them. A test may permit earlier rejection, but must assert the expected Swift partial state; it cannot ignore differing rows globally.

Do not assign a source GTID to target SQL merely to provoke the native error. Swift-owned target connections keep GTID_NEXT=AUTOMATIC; SQLite owns source progress. Native results are an offline test reference used to define the compatibility policy, not a runtime dependency on a parallel native replica. Detect supported/rejected shapes from decoded events and historical schema. Preserve statement boundaries as well as transaction boundaries; row count alone does not establish the number of source statements. Ambiguous classification blocks and remains a coverage gap until qualified.

## Phase gates

Phase 1 now needs reproducible positive and expected-negative native cases, rather than a fix that makes the known multi-statement case succeed. The suite must assert the specific expected SQL failure, source transaction boundary, receiver state and partial rows; record observed native failure separately from the result of those assertions. Raw `make native-smoke` still exits nonzero for the negative case. An expectation-aware suite runner has not yet been implemented. Comparator/corpus, failure controls, ABI and Ubuntu packaging gates remain outstanding.

Phase 2 must preserve the event/statement/transaction information needed for classification. It may decode valid transactions that Phase 3 will reject for target compatibility; parsing success does not promise apply support.

Phase 3 compares Swift positive data/binlog effects and negative stop/diagnostic/checkpoint behavior with the cataloged native outcomes. Include a later transaction behind the rejected transaction, blocked restart and failed/unfixed resume tests. Matching only an error code is insufficient. Do not count unimplemented Swift tests as passing based on native results.

This decision removes the need to solve native error 1837 before progressing with the bounded implementation. It does not complete Phase 1 or establish production workload coverage; fleet transaction-shape inventory is still needed to assess how often the initial policy would stop replication.
