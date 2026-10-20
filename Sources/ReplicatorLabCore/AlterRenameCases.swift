import Foundation

extension DDLCompatibilityCases {
    static let alterTableRename = Case(
        "alter-table-rename", "Compound ALTER renames, FK peers, cross-schema moves, restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.parent(id INT PRIMARY KEY,a INT,note VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "CREATE TABLE ddlcompat.child(cid INT PRIMARY KEY,pid INT)",
                sqlTransactional:
                    "CREATE TABLE ddlcompat.child(cid INT PRIMARY KEY,pid INT,CONSTRAINT child_fk FOREIGN KEY(pid) REFERENCES ddlcompat.parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.parent VALUES(1,10,'first')"),
            .init("INSERT INTO ddlcompat.child VALUES(10,1)"),
            .init("ALTER TABLE ddlcompat.parent ADD n INT DEFAULT 7"),
            .init(
                "ALTER TABLE ddlcompat.parent RENAME TO otherdb.moved,CHANGE id new_id INT",
                [
                    .init("SELECT new_id,a,n FROM otherdb.moved", "1\t10\t7"),
                    .init("SELECT COUNT(*) FROM ddlcompat.child c JOIN otherdb.moved p ON c.pid=p.new_id", "1"),
                ], restartBefore: true),
            .init(
                "UPDATE otherdb.moved SET a=11 WHERE new_id=1",
                [.init("SELECT COUNT(*) FROM ddlcompat.child c JOIN otherdb.moved p ON c.pid=p.new_id", "1")],
                sqlTransactional: "UPDATE otherdb.moved SET new_id=2,a=11 WHERE new_id=1"),
            .init(
                "ALTER TABLE ddlcompat.child ADD note INT DEFAULT 3,RENAME AS otherdb.kid",
                [.init("SELECT cid,note FROM otherdb.kid", "10\t3")], restartBefore: true),
            .init(
                "ALTER TABLE otherdb.kid MODIFY note BIGINT,RENAME ddlcompat.child",
                sqlTransactional:
                    "ALTER TABLE otherdb.kid RENAME ddlcompat.child,DROP FOREIGN KEY child_fk,ADD CONSTRAINT new_fk FOREIGN KEY(pid) REFERENCES otherdb.moved(new_id) ON UPDATE CASCADE,MODIFY note BIGINT"
            ),
            .init(
                "ALTER TABLE otherdb.moved RENAME otherdb.unused_name,MODIFY note VARCHAR(30),RENAME TO ddlcompat.parent",
                [.init("SELECT a,n FROM ddlcompat.parent", "11\t7")], restartBefore: true),
            .init("ALTER TABLE ddlcompat.parent ADD flag INT DEFAULT 9,RENAME TO ddlcompat.parent"),
            .init(
                "UPDATE ddlcompat.parent SET n=8",
                [.init("SELECT COUNT(*) FROM ddlcompat.child c JOIN ddlcompat.parent p ON c.pid=p.new_id", "1")],
                sqlTransactional: "UPDATE ddlcompat.parent SET new_id=3,n=8"),
            .init("ALTER TABLE ddlcompat.child RENAME AS ddlcompat.temporary_child", restartBefore: true),
            .init("ALTER TABLE ddlcompat.temporary_child RENAME ddlcompat.child"),
            .init("DELETE FROM ddlcompat.child WHERE cid=10"),
            .init("DELETE FROM ddlcompat.parent"),
            .init("DROP TABLE ddlcompat.child,ddlcompat.parent"),
        ])
}

extension SharedCorrectness.Run {
    func rejectUnsafeTarget84Rename() throws {
        guard f.profile == .reverse, selects("alter-rename-target84-refusal") else { return }
        try reporter.run(
            .init("alter-rename-target84-refusal", "Refuse a native 8.4 parent rename defect before target SQL")
        ) {
            let setup =
                "SET sql_log_bin=0;CREATE DATABASE rename_refusal;CREATE TABLE rename_refusal.p(id INT PRIMARY KEY);CREATE TABLE rename_refusal.c(id INT PRIMARY KEY,p INT,CONSTRAINT fk FOREIGN KEY(p) REFERENCES rename_refusal.p(id) ON UPDATE CASCADE);INSERT INTO rename_refusal.p VALUES(1);INSERT INTO rename_refusal.c VALUES(1,1)"
            for role in LabProfile.Role.allCases { _ = try f.sql(role, setup) }
            let isolated = LabIsolatedApply(f)
            let label = "rename-native84-refusal"
            let start = try f.boundary()
            let config = isolated.configuration(label, at: start, count: 1)
            _ = try f.sql(
                .source,
                session
                    + "ALTER TABLE rename_refusal.p RENAME rename_refusal.moved,CHANGE id new_id INT,ADD n INT DEFAULT 7"
            )
            try f.awaitNative()
            let client = try isolated.start(label, config: config)
            let result = try isolated.finish(
                client, label: label, config: config, reason: "target MySQL 8.4 native ALTER limitation")
            let progress = result["progress"] as? [String: Any]
            let failure = progress?["targetFailure"] as? [String: Any]
            let statement = failure?["statement"] as? [String: Any]
            try require(statement?["phase"] as? String == "notIssued", "unsafe native ALTER reached the target")
            try require(
                isolated.state(label, "SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0",
                "native ALTER refusal advanced progress")
            try require(
                f.sql(.target, "SELECT id FROM rename_refusal.p") == "1", "native ALTER refusal changed target rows")
            try require(
                f.sql(
                    .target,
                    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='rename_refusal' AND TABLE_NAME='moved'"
                ) == "0", "native ALTER refusal renamed the target")
        }
    }
}
