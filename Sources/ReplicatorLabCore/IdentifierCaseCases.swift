import Foundation

extension DMLCompatibilityCases {
    static let identifierCase = Case(
        id: "identifiercase", definition: "id INT,Value INT DEFAULT 7,PRIMARY KEY(ID),KEY ValueKey(VALUE)",
        phases: [
            .init(
                sql: "INSERT INTO poc.matrix_identifiercase(ID) VALUES(1),(2)",
                check: "SELECT COUNT(*)=2 AND SUM(VALUE)=14 FROM poc.matrix_identifiercase"),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_identifiercase ALTER COLUMN VALUE SET DEFAULT 9, ADD extra INT DEFAULT 3 AFTER VALUE; UPDATE poc.matrix_identifiercase SET VALUE=DEFAULT,EXTRA=4 WHERE ID=1",
                check: "SELECT COUNT(*)=1 FROM poc.matrix_identifiercase WHERE id=1 AND Value=9 AND extra=4"),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_identifiercase CHANGE VALUE renamed BIGINT DEFAULT 5; ALTER TABLE poc.matrix_identifiercase RENAME INDEX valuekey TO RenamedKey; UPDATE poc.matrix_identifiercase SET RENAMED=DEFAULT WHERE ID=2",
                check: "SELECT COUNT(*)=1 FROM poc.matrix_identifiercase WHERE id=2 AND renamed=5"),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_identifiercase DROP INDEX renamedkey, DROP COLUMN EXTRA; DELETE FROM poc.matrix_identifiercase WHERE ID=1",
                check: "SELECT COUNT(*)=1 AND SUM(RENAMED)=5 FROM poc.matrix_identifiercase"),
        ],
        workflow: .init(
            title: "Identifier case sensitivity: column, PRIMARY KEY and index references",
            histories: [
                .init(table: "ic_after_insert", throughPhase: 1),
                .init(table: "ic_after_alter", throughPhase: 2),
                .init(table: "ic_after_rename", throughPhase: 3),
            ], phaseTransactions: [1, 2, 3, 2],
            predicateIDs: [
                "inserted-defaults", "altered-default-and-row", "renamed-index-and-row", "deleted-final-row",
            ],
            additionalChecks: [
                .init(
                    id: "initial-rows",
                    check: .init("SELECT id,Value FROM poc.ic_after_insert ORDER BY id", "1\t7\n2\t7")),
                .init(
                    id: "altered-rows",
                    check: .init("SELECT id,Value,extra FROM poc.ic_after_alter ORDER BY id", "1\t9\t4\n2\t7\t3")),
                .init(
                    id: "renamed-rows",
                    check: .init("SELECT id,renamed,extra FROM poc.ic_after_rename ORDER BY id", "1\t9\t4\n2\t5\t3")),
                .init(
                    id: "surviving-row",
                    check: .init("SELECT id,renamed FROM poc.matrix_identifiercase ORDER BY id", "2\t5")),
                .init(
                    id: "retained-index-name",
                    check: .init(
                        "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ic_after_rename' AND INDEX_NAME<>'PRIMARY' ORDER BY SEQ_IN_INDEX",
                        "RenamedKey")),
                .init(
                    id: "dropped-secondary-index",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_identifiercase' AND INDEX_NAME<>'PRIMARY'",
                        "0")),
            ], expectedDDL: 12, expectedRows: 14))
}
