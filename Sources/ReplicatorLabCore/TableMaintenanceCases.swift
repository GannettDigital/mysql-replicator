import Foundation

extension DDLCompatibilityCases {
    static let tableMaintenance = Case(
        "table-maintenance", "ALTER TABLE: FORCE and ENABLE/DISABLE KEYS",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,v INT,doubled INT AS(v*2) STORED,KEY by_v(v))"),
            .init("INSERT INTO ddlcompat.t(id,v) VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.t DISABLE KEYS", phaseEnd: "prepare-and-disable-keys"),
            .init("INSERT INTO ddlcompat.t(id,v) VALUES(3,30)", restartBefore: true),
            .init("UPDATE ddlcompat.t SET v=11 WHERE id=1"),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init("ALTER TABLE ddlcompat.t ENABLE KEYS", phaseEnd: "write-and-enable-keys"),
            .init("ALTER TABLE ddlcompat.t FORCE", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t FORCE, ADD note INT DEFAULT 7", phaseEnd: "rebuild-and-add-column"),
            .init("DELETE FROM ddlcompat.t WHERE id=3", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.tm_disabled(id INT PRIMARY KEY,v INT,doubled INT AS(v*2) STORED,KEY by_v(v))"),
            .init("INSERT INTO ddlcompat.tm_disabled(id,v) VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.tm_disabled DISABLE KEYS"),
            .init("INSERT INTO ddlcompat.tm_disabled(id,v) VALUES(3,30)"),
            .init("UPDATE ddlcompat.tm_disabled SET v=11 WHERE id=1"),
            .init("DELETE FROM ddlcompat.tm_disabled WHERE id=2"),
            .init("CREATE TABLE ddlcompat.tm_enabled(id INT PRIMARY KEY,v INT,doubled INT AS(v*2) STORED,KEY by_v(v))"),
            .init("INSERT INTO ddlcompat.tm_enabled(id,v) VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.tm_enabled DISABLE KEYS"),
            .init("INSERT INTO ddlcompat.tm_enabled(id,v) VALUES(3,30)"),
            .init("UPDATE ddlcompat.tm_enabled SET v=11 WHERE id=1"),
            .init("DELETE FROM ddlcompat.tm_enabled WHERE id=2"),
            .init("ALTER TABLE ddlcompat.tm_enabled ENABLE KEYS"),
            .init("CREATE TABLE ddlcompat.tm_rebuilt(id INT PRIMARY KEY,v INT,doubled INT AS(v*2) STORED,KEY by_v(v))"),
            .init("INSERT INTO ddlcompat.tm_rebuilt(id,v) VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.tm_rebuilt DISABLE KEYS"),
            .init("INSERT INTO ddlcompat.tm_rebuilt(id,v) VALUES(3,30)"),
            .init("UPDATE ddlcompat.tm_rebuilt SET v=11 WHERE id=1"),
            .init("DELETE FROM ddlcompat.tm_rebuilt WHERE id=2"),
            .init("ALTER TABLE ddlcompat.tm_rebuilt ENABLE KEYS"),
            .init("ALTER TABLE ddlcompat.tm_rebuilt FORCE", phaseEnd: "delete-and-retain-index-states"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "disabled-nonunique-index",
                    check: .init(
                        "SHOW INDEX FROM ddlcompat.tm_disabled WHERE Key_name='by_v'", "by_v\tBTREE\t",
                        fields: [2, 10, 11], myISAMExpected: "by_v\tBTREE\tdisabled")),
                .init(
                    id: "writes-with-disabled-index",
                    check: .init("SELECT id,v,doubled FROM ddlcompat.tm_disabled ORDER BY id", "1\t11\t22\n3\t30\t60")),
                .init(
                    id: "enabled-nonunique-index",
                    check: .init(
                        "SHOW INDEX FROM ddlcompat.tm_enabled WHERE Key_name='by_v'", "by_v\tBTREE\t",
                        fields: [2, 10, 11])),
                .init(
                    id: "enabled-index-query",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.tm_enabled FORCE INDEX(by_v) WHERE v>=11", "2")),
                .init(
                    id: "standalone-force-rows",
                    check: .init("SELECT id,v,doubled FROM ddlcompat.tm_rebuilt ORDER BY id", "1\t11\t22\n3\t30\t60")),
                .init(
                    id: "compound-force-add-and-delete",
                    check: .init("SELECT id,v,doubled,note FROM ddlcompat.t ORDER BY id", "1\t11\t22\t7")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.tm_disabled,ddlcompat.tm_enabled,ddlcompat.tm_rebuilt"]))

}
