import Foundation

extension DDLCompatibilityCases {
    static let temporaryTables = Case(
        "temporary", "Temporary tables: permanent row effects, name hiding and CREATE TABLE ... LIKE",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init(
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp(id INT PRIMARY KEY,n INT); INSERT INTO tmp VALUES(1,7),(2,8); INSERT INTO ddlcompat.t SELECT * FROM tmp; DROP TEMPORARY TABLE tmp"
            ),
            .init(
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp(id INT PRIMARY KEY,n INT) ENGINE=MyISAM; CREATE TABLE ddlcompat.cloned LIKE tmp; DROP TEMPORARY TABLE tmp",
                sqlTransactional:
                    "USE ddlcompat; CREATE TEMPORARY TABLE tmp(id INT PRIMARY KEY,n INT) ENGINE=InnoDB; CREATE TABLE ddlcompat.cloned LIKE tmp; DROP TEMPORARY TABLE tmp"
            ),
            .init("INSERT INTO ddlcompat.cloned VALUES(3,9)"),
            .init(
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp(id INT PRIMARY KEY,n INT) ENGINE=MyISAM; CREATE TABLE ddlcompat.tt_empty_clone LIKE tmp; DROP TEMPORARY TABLE tmp",
                sqlTransactional:
                    "USE ddlcompat; CREATE TEMPORARY TABLE tmp(id INT PRIMARY KEY,n INT) ENGINE=InnoDB; CREATE TABLE ddlcompat.tt_empty_clone LIKE tmp; DROP TEMPORARY TABLE tmp",
                phaseEnd: "temporary-rows-and-like-clones"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "permanent-insert-select-rows",
                    check: .init("SELECT * FROM ddlcompat.t ORDER BY id", "1\t7\n2\t8")),
                .init(id: "empty-like-clone", check: .init("SELECT COUNT(*) FROM ddlcompat.tt_empty_clone", "0")),
                .init(id: "following-clone-insert", check: .init("SELECT * FROM ddlcompat.cloned", "3\t9")),
                .init(id: "permanent-name-survives", check: .init("SELECT * FROM ddlcompat.tmp", "99\t99")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.tt_empty_clone"]
        ))
    static let temporaryCreateSelect = Case(
        "temporary-create-select", "CREATE TEMPORARY TABLE ... SELECT: permanent row effects and replay",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20)"),
            .init(
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp (PRIMARY KEY(id)) SELECT * FROM t; UPDATE tmp SET n=n+1; INSERT INTO t SELECT id+10,n FROM tmp; DROP TEMPORARY TABLE tmp",
                phaseEnd: "insert-from-temporary-select"),
            .init(
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp SELECT * FROM t WHERE 0; INSERT INTO tmp VALUES(99,99); UPDATE t JOIN tmp ON t.id=tmp.id-98 SET t.n=tmp.n; DROP TEMPORARY TABLE tmp",
                restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init("CREATE TABLE ddlcompat.tt_ctas_inserted(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.tt_ctas_inserted VALUES(1,10),(2,20)"),
            .init(
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp (PRIMARY KEY(id)) SELECT * FROM tt_ctas_inserted; UPDATE tmp SET n=n+1; INSERT INTO tt_ctas_inserted SELECT id+10,n FROM tmp; DROP TEMPORARY TABLE tmp"
            ),
            .init("CREATE TABLE ddlcompat.tt_ctas_updated(id INT PRIMARY KEY,n INT)"),
            .init("INSERT INTO ddlcompat.tt_ctas_updated VALUES(1,10),(2,20)"),
            .init(
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp (PRIMARY KEY(id)) SELECT * FROM tt_ctas_updated; UPDATE tmp SET n=n+1; INSERT INTO tt_ctas_updated SELECT id+10,n FROM tmp; DROP TEMPORARY TABLE tmp"
            ),
            .init(
                "USE ddlcompat; CREATE TEMPORARY TABLE tmp SELECT * FROM tt_ctas_updated WHERE 0; INSERT INTO tmp VALUES(99,99); UPDATE tt_ctas_updated JOIN tmp ON tt_ctas_updated.id=tmp.id-98 SET tt_ctas_updated.n=tmp.n; DROP TEMPORARY TABLE tmp",
                phaseEnd: "update-delete-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "insert-from-temporary-rows",
                    check: .init("SELECT * FROM ddlcompat.tt_ctas_inserted ORDER BY id", "1\t10\n2\t20\n11\t11\n12\t21")
                ),
                .init(
                    id: "no-permanent-temporary-table",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='tmp'",
                        "0")),
                .init(
                    id: "update-join-rows",
                    check: .init("SELECT * FROM ddlcompat.tt_ctas_updated ORDER BY id", "1\t99\n2\t20\n11\t11\n12\t21")),
                .init(
                    id: "following-delete-rows",
                    check: .init("SELECT * FROM ddlcompat.t ORDER BY id", "1\t99\n11\t11\n12\t21")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.tt_ctas_inserted,ddlcompat.tt_ctas_updated"]
        ))
}

enum TemporaryTableWorkflowEvidence {
    static func additionalSetup(_ caseID: String) -> [LabSQLPhase.Write] {
        guard caseID == "ddl-compat-temporary" else { return [] }
        return [
            .init(id: "permanent-same-name-table", sql: "CREATE TABLE ddlcompat.tmp(id INT PRIMARY KEY,n INT)"),
            .init(id: "permanent-same-name-row", sql: "INSERT INTO ddlcompat.tmp VALUES(99,99)"),
        ]
    }

    static func explicitMyISAMClone(profile: LabProfile, role: LabProfile.Role, database: String, table: String) -> Bool
    {
        !profile.transactionalTarget && role == .source && database == "ddlcompat"
            && ["cloned", "tt_empty_clone"].contains(table)
    }

    static let cleanupReason = "row replication temporary-table cleanup"
    static let cleanupSQL = "SELECT COUNT(*) FROM ddl_skips WHERE reason='row replication temporary-table cleanup'"

    static func cleanupObservation(_ count: String) throws -> [String: Any] {
        guard let value = UInt64(count), value > 0 else {
            throw LabError("temporary-table cleanup missing from durable audit: " + count)
        }
        return ["count": count, "reason": cleanupReason]
    }
}
