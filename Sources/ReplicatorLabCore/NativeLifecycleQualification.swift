import Foundation

/// Native acceptance/logging observations precede Swift support. Every case has
/// independent, externally prepared state; setup is deliberately not binlogged.
enum NativeLifecycleQualification {
    struct Case {
        let test: QualificationCase
        let sql: String
        let existing: Bool
        let database: String
        let error: Int?
        let warning: Int?
        let present: Bool
        let rows: String
        init(_ id: String, _ name: String, _ sql: String, existing: Bool = false, database: String = "poc",
             error: Int? = nil, warning: Int? = nil, present: Bool = true, rows: String = "", file: String = #filePath, line: UInt = #line) {
            test = QualificationCase(id, name, file: file, line: line)
            self.sql = sql; self.existing = existing; self.database = database
            self.error = error; self.warning = warning; self.present = present; self.rows = rows
        }
    }
    static let definition = "(note VARCHAR(20) COLLATE utf8mb4_bin,id INT PRIMARY KEY) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
    static let cases: [Case] = [
        .init("native-create-if-absent", "Conditional CREATE of an absent table logs a DDL event", "CREATE TABLE IF NOT EXISTS poc.lifecycle " + definition),
        .init("native-create-if-matching", "Conditional CREATE with matching definition preserves existing rows", "CREATE TABLE IF NOT EXISTS poc.lifecycle " + definition, existing: true, warning: 1050, rows: "1\t73656564"),
        .init("native-create-if-different", "Conditional CREATE ignores a different supported definition", "CREATE TABLE IF NOT EXISTS poc.lifecycle(id BIGINT UNSIGNED PRIMARY KEY,b VARBINARY(10))", existing: true, warning: 1050, rows: "1\t73656564"),
        .init("native-drop-if-present", "Conditional DROP removes an existing table and logs the statement", "DROP TABLE IF EXISTS poc.lifecycle", existing: true, present: false),
        .init("native-drop-if-absent", "Conditional DROP of an absent table warns and logs the statement", "DROP TABLE IF EXISTS poc.lifecycle", warning: 1051, present: false),
        .init("native-like-same", "CREATE LIKE copies local engine, encoding and primary key without copying rows", "CREATE TABLE poc.lifecycle LIKE poc.native_template"),
        .init("native-like-cross", "Cross-schema CREATE LIKE inherits template defaults over destination defaults", "CREATE TABLE otherdb.lifecycle LIKE poc.native_template", database: "otherdb"),
        .init("native-like-conditional", "Conditional CREATE LIKE preserves existing destination rows", "CREATE TABLE IF NOT EXISTS poc.lifecycle LIKE poc.native_template", existing: true, warning: 1050, rows: "1\t73656564"),
        .init("native-like-existing", "CREATE LIKE rejects an existing destination without a binlog event", "CREATE TABLE poc.lifecycle LIKE poc.native_template", existing: true, error: 1050, rows: "1\t73656564"),
        .init("native-like-missing-template", "CREATE LIKE rejects a missing template without a binlog event", "CREATE TABLE poc.lifecycle LIKE poc.missing_template", error: 1146, present: false),
        .init("native-like-missing-database", "CREATE LIKE rejects a missing destination schema without a binlog event", "CREATE TABLE no_such_schema.lifecycle LIKE poc.native_template", database: "no_such_schema", error: 1049, present: false),
        .init("native-like-conditional-missing", "Conditional CREATE LIKE still requires its template when the destination exists", "CREATE TABLE IF NOT EXISTS poc.lifecycle LIKE poc.missing_template", existing: true, error: 1146, rows: "1\t73656564")
    ]

    static func run(_ h: NativeHarness, reporter: QualificationReporter) throws {
        var observations: [[String: Any]] = []
        for test in cases {
            try reporter.run(test.test) {
                for service in h.services {
                    var setup = "SET SESSION sql_log_bin=0; DROP TABLE IF EXISTS poc.lifecycle,poc.native_template,otherdb.lifecycle; CREATE TABLE poc.native_template " + definition + "; INSERT INTO poc.native_template VALUES('template',9)"
                    if test.existing { setup += "; CREATE TABLE poc.lifecycle " + definition + "; INSERT INTO poc.lifecycle VALUES('seed',1)" }
                    _ = try h.sql(service, setup)
                }
                let before = try h.boundary("source")
                func attempt(_ service: String) throws -> CommandResult {
                    try h.compose(["exec", "-T", "-e", "MYSQL_PWD=fixture-root-only", service, "mysql", "--no-defaults", "-uroot", "--batch", "--raw", "--skip-column-names", "-e", test.sql + "; SHOW WARNINGS"], checked: false)
                }
                let source = try attempt("source"), direct = try attempt("target57")
                let after = try h.boundary("source")
                var row: [String: Any] = ["id": test.test.id, "sql": test.sql, "before": before.json, "after": after.json,
                    "source_stdout": source.text, "source_stderr": String(decoding: source.stderr, as: UTF8.self),
                    "target57_stdout": direct.text, "target57_stderr": String(decoding: direct.stderr, as: UTF8.self)]
                if let code = test.error {
                    for result in [source, direct] { try require(result.status != 0 && String(decoding: result.stderr, as: UTF8.self).contains("ERROR \(code) "), "wrong native/direct source rejection for \(test.test.id)") }
                    try require(before.file == after.file && before.position == after.position && before.gtids == after.gtids, "rejected source DDL unexpectedly logged an event")
                    row["logging"] = "no_event"
                } else {
                    try require(source.status == 0 && direct.status == 0, "native/direct lifecycle statement failed")
                    for result in [source, direct] {
                        let codes = result.text.split(separator: "\n").compactMap { line -> Int? in
                            let fields = line.split(separator: "\t")
                            return fields.count >= 2 ? Int(fields[1]) : nil
                        }
                        try require(codes == (test.warning.map { [$0] } ?? []), "lifecycle warning mismatch: \(result.text)")
                    }
                    try require(before.file == after.file && after.position > before.position && after.gtids != before.gtids, "successful lifecycle statement did not produce expected source event")
                    let reached = try h.sql("native", "SELECT SOURCE_POS_WAIT('\(after.file)',\(after.position),20)")
                    try require(reached != "NULL" && reached != "-1", "native lifecycle replication did not converge")
                    row["logging"] = "event"
                }
                try require(h.status()["Last_SQL_Errno"] == "0", "unexpected native lifecycle replication error")
                for service in h.services {
                    let schema = try h.sql(service, "SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE,COLUMN_KEY,IFNULL(COLLATION_NAME,'') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(test.database)' AND TABLE_NAME='lifecycle' ORDER BY ORDINAL_POSITION")
                    if test.present {
                        try require(schema == "note\tvarchar\tYES\t\tutf8mb4_bin\nid\tint\tNO\tPRI", "native lifecycle schema differs: \(schema)")
                        try require(h.sql(service, "SELECT id,HEX(note) FROM \(test.database).lifecycle ORDER BY id") == test.rows, "native lifecycle retained/copied rows differ")
                        let defaults = try h.sql(service, "SELECT ENGINE,TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(test.database)' AND TABLE_NAME='lifecycle'")
                        try require(defaults == (service == "source" ? "InnoDB" : "MyISAM") + "\tutf8mb4_unicode_ci", "CREATE LIKE/default engine or encoding inheritance differs")
                        row[service + "_defaults"] = defaults
                    } else { try require(schema.isEmpty, "native lifecycle table remains") }
                    row[service + "_schema"] = schema
                }
                observations.append(row)
                try writeJSON(observations, to: h.output.appendingPathComponent("lifecycle-matrix.json"))
            }
        }
        for service in h.services { _ = try h.sql(service, "SET SESSION sql_log_bin=0; DROP TABLE IF EXISTS poc.lifecycle,poc.native_template,otherdb.lifecycle") }
    }
}
