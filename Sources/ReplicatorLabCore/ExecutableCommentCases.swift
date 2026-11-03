import Foundation

extension DDLCompatibilityCases {
    static let executableComments = Case(
        "executable-comments", "Executable comments: version numbers, quoted text and row changes",
        [
            .init(
                "/*!50700 CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT DEFAULT 3,note VARCHAR(40) DEFAULT '/*! keep */') */"
            ),
            .init("INSERT INTO ddlcompat.t(id) VALUES(1)", phaseEnd: "create-and-insert"),
            .init("ALTER TABLE ddlcompat.t /*!50700 ADD extra INT DEFAULT 7 */", restartBefore: true),
            .init("UPDATE ddlcompat.t SET n=4 WHERE id=1"),
            .init(
                "ALTER TABLE ddlcompat.t ADD last_col INT DEFAULT 9 /*!99999 , ADD future_col INT */",
                phaseEnd: "add-columns-and-update"),
            .init("/*! ALTER TABLE ddlcompat.t MODIFY last_col BIGINT DEFAULT 9 */", restartBefore: true),
            .init("INSERT INTO ddlcompat.t(id) VALUES(2)"),
            .init("DELETE FROM ddlcompat.t WHERE id=1"),
            .init("CREATE DATABASE executable_comment_results CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init(
                "/*!50700 CREATE TABLE executable_comment_results.ec_after_update(id INT PRIMARY KEY,n INT DEFAULT 3,note VARCHAR(40) DEFAULT '/*! keep */') */"
            ),
            .init("INSERT INTO executable_comment_results.ec_after_update(id) VALUES(1)"),
            .init("ALTER TABLE executable_comment_results.ec_after_update /*!50700 ADD extra INT DEFAULT 7 */"),
            .init(
                "UPDATE executable_comment_results.ec_after_update SET n=4 WHERE id=1",
                phaseEnd: "modify-delete-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "updated-row-and-literal",
                    check: .init(
                        "SELECT id,n,note,extra FROM executable_comment_results.ec_after_update", "1\t4\t/*! keep */\t7"
                    )),
                .init(
                    id: "remaining-row-defaults",
                    check: .init("SELECT id,n,extra,last_col FROM ddlcompat.t", "2\t3\t7\t9")),
                .init(
                    id: "last-column-type",
                    check: .init(
                        "SELECT DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='last_col'",
                        "bigint")),
                .init(
                    id: "future-column-absent",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='future_col'",
                        "0")),
            ], databases: ["ddlcompat", "executable_comment_results"],
            cleanup: ["DROP DATABASE executable_comment_results"]
        ))
    static let executableCommentsTargetGate = Case(
        "executable-comments-target-gate", "Executable comments: active on source, inactive on older target",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)", phaseEnd: "create-table"),
            .init("/*!80400 ALTER TABLE ddlcompat.t COMMENT='source-only' */", restartBefore: true),
            .init("INSERT INTO ddlcompat.t VALUES(1,2)"),
            .init("UPDATE ddlcompat.t SET n=3 WHERE id=1", phaseEnd: "versioned-alter-and-row-changes"),
        ],
        profileExclusions: [
            .reverse: "Requires an 8.4 source and a 5.7 target.",
            .mysql57MyISAM: "Requires an 8.4 source and a 5.7 target.",
            .mysql57InnoDB: "Requires an 8.4 source and a 5.7 target.",
        ],
        finalObservations: .init(
            checks: [
                .init(id: "final-row", check: .init("SELECT id,n FROM ddlcompat.t", "1\t3"))
            ], databases: ["ddlcompat"],
            cleanup: []
        ))
    static let executableCommentsSourceGate = Case(
        "executable-comments-source-gate", "Executable comments: inactive on source, ordinary comment in binlog",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY)", phaseEnd: "create-table"),
            .init("ALTER TABLE ddlcompat.t ADD n INT DEFAULT 7 /*!80000 , ADD future_col INT */", restartBefore: true),
            .init("INSERT INTO ddlcompat.t VALUES(1,8)"),
            .init("UPDATE ddlcompat.t SET n=9 WHERE id=1", phaseEnd: "source-disabled-clause-and-row-changes"),
        ],
        profileExclusions: [
            .forward: "This case tests a comment disabled by the 5.7 source."
        ],
        finalObservations: .init(
            checks: [
                .init(id: "final-row", check: .init("SELECT id,n FROM ddlcompat.t", "1\t9")),
                .init(
                    id: "future-column-absent",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='future_col'",
                        "0")),
            ], databases: ["ddlcompat"],
            cleanup: []
        ))
}

enum ExecutableCommentWorkflowEvidence {
    static let tableCommentSQL =
        "SELECT TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'"

    static func originalGTID(_ caseID: String, writes: [LabSQLPhase.Result]) throws -> String {
        let index: Int
        switch caseID {
        case "ddl-compat-executable-comments": index = 5
        case "ddl-compat-executable-comments-target-gate", "ddl-compat-executable-comments-source-gate": index = 1
        default: throw LabError("unknown executable-comment case: " + caseID)
        }
        try require(writes.indices.contains(index), "executable-comment source results are incomplete")
        let gtid = writes[index].gtids
        try require(
            try DMLCompatibilityCases.transactionCount(gtid) == 1, "comment operation must have one source GTID")
        return gtid
    }

    static func journalSQL(_ caseID: String, writes: [LabSQLPhase.Result]) throws -> String {
        let gtid = try originalGTID(caseID, writes: writes)
        let predicate =
            caseID == "ddl-compat-executable-comments-source-gate"
            ? "source_sql LIKE '%/* 80000%' AND source_sql=target_sql AND status='DONE'"
            : "source_sql LIKE '%/*!%ALTER%' AND source_sql=target_sql AND context_json LIKE '%target-version-executable-comments%' AND status='DONE'"
        return "SELECT COUNT(*) FROM ddl_details JOIN ddl_intents USING(gtid) WHERE " + predicate
            + " AND ddl_intents.gtid=" + LabSQLName.sqliteLiteral(gtid)
    }

    static func journalObservation(_ count: String, caseID: String) throws -> [String: Any] {
        let exact = caseID == "ddl-compat-executable-comments-source-gate"
        guard let value = UInt64(count), exact ? value == 1 : value > 0 else {
            throw LabError("original executable-comment journal count differs: " + count)
        }
        return ["count": count, "expected": exact ? "1" : "nonzero"]
    }

    static func tableComment(_ value: String, role: LabProfile.Role) throws -> [String: Any] {
        let expected = role == .target ? "" : "source-only"
        try require(value == expected, "native target version comment differs for " + role.rawValue)
        return ["query": tableCommentSQL, "value": value, "expected": expected]
    }
}
