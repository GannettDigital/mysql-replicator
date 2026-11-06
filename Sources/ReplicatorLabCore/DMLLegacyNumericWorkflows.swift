import Foundation

/// The four legacy declarations share source operations and retained results.
enum DMLLegacyNumericWorkflows {
    static func make(suffix: String, type: String) -> DMLExecutionWorkflow {
        let original = "matrix_floatingauto" + suffix
        let inserted = "fai_" + suffix + "_insert"
        let updated = "fai_" + suffix + "_update"
        let altered = "fai_" + suffix + "_alter"
        func rows(_ id: String, table: String, added: Bool = false, expected: String)
            -> DDLFinalObservations.Observation
        {
            .init(
                id: id,
                check: .init(
                    "SELECT CAST(id AS DECIMAL(12,2)),IFNULL(CAST(v AS CHAR),'NULL')"
                        + (added ? ",IFNULL(CAST(extra AS CHAR),'NULL')" : "")
                        + " FROM poc." + table + " ORDER BY id", expected))
        }
        func columns(_ id: String, table: String, added: Bool = false) -> DDLFinalObservations.Observation {
            .init(
                id: id,
                check: .init(
                    "SELECT COLUMN_NAME,IF(COLUMN_NAME='id',COLUMN_TYPE,DATA_TYPE),IS_NULLABLE,EXTRA='auto_increment' FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='"
                        + table + "' ORDER BY ORDINAL_POSITION",
                    "id\t" + type.lowercased() + "\tNO\t1\nv\tint\tYES\t0"
                        + (added ? "\nextra\tint\tYES\t0" : "")))
        }
        let tables = [inserted, updated, altered, original]
        // InnoDB can reserve unused values. Source-generated IDs stay in the row checks.
        let minimumNext = [inserted: 3, updated: 102, altered: 103, original: 103]
        let limits = tables.map { "WHEN '" + $0 + "' THEN " + String(minimumNext[$0]!) }.joined(separator: " ")
        let names = tables.map { "'" + $0 + "'" }.joined(separator: ",")
        let nextSQL =
            "SELECT TABLE_NAME,AUTO_INCREMENT>=CASE TABLE_NAME " + limits
            + " END FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME IN ("
            + names + ") ORDER BY BINARY TABLE_NAME"
        let nextExpected = tables.sorted().map { $0 + "\t1" }.joined(separator: "\n")
        return DMLExecutionWorkflow(
            title: "Legacy AUTO_INCREMENT: " + type + " generated values, zero and key changes",
            histories: [
                .init(table: inserted, throughPhase: 1),
                .init(table: updated, throughPhase: 2),
                .init(table: altered, throughPhase: 3),
            ], phaseTransactions: [1, 2, 2, 1],
            predicateIDs: [
                "inserted-generated-and-explicit-zero", "changed-key-and-generated-after-high-value",
                "added-default-and-changed-generated-key", "deleted-low-keys",
            ],
            additionalChecks: [
                rows("initial-rows", table: inserted, expected: "0.00\t33\n1.00\t11\n2.00\t22"),
                rows(
                    "updated-rows", table: updated,
                    expected: "0.00\t33\n2.00\t22\n9.50\t110\n100.00\t44\n101.00\t55"),
                rows(
                    "altered-rows", table: altered, added: true,
                    expected: "0.00\t33\t7\n2.00\t22\t7\n9.50\t110\t7\n100.00\t44\t7\n102.00\t55\t8"),
                rows(
                    "final-rows", table: original, added: true, expected: "9.50\t110\t7\n100.00\t44\t7\n102.00\t55\t8"),
                columns("initial-column-attributes", table: inserted),
                columns("altered-column-attributes", table: altered, added: true),
                .init(
                    id: "added-column-default",
                    check: .init("SELECT DEFAULT(extra) FROM poc." + altered + " WHERE id=102", "7")),
                .init(
                    id: "next-values-exceed-retained-keys",
                    check: .init(nextSQL, nextExpected)),
            ], expectedDDL: 6, expectedRows: 25)
    }
}
