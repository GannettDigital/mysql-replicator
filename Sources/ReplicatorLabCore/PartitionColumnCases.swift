import Foundation

extension DDLCompatibilityCases {
    static let partitionColumnBounds = Case(
        "partition-column-bounds", "RANGE COLUMNS and LIST COLUMNS: binary, character and date bounds",
        [
            // Keep the original operations and restart boundaries before the retained histories.
            .init(
                "CREATE TABLE ddlcompat.t(v VARBINARY(10) PRIMARY KEY,n INT) PARTITION BY RANGE COLUMNS(v)(PARTITION p VALUES LESS THAN(X'80FF'),PARTITION q VALUES LESS THAN(MAXVALUE))"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(X'0080',1),(X'80FE',2),(X'80FF',3),(X'FF',4)"),
            .init(
                "ALTER TABLE ddlcompat.t REORGANIZE PARTITION q INTO(PARTITION middle VALUES LESS THAN(_binary X'F0'),PARTITION q VALUES LESS THAN(MAXVALUE))",
                phaseEnd: "seed-and-reorganize"),
            .init("UPDATE ddlcompat.t SET v=X'81' WHERE v=X'80FE'", restartBefore: true),
            .init(
                "CREATE TABLE ddlcompat.s(v VARCHAR(10) CHARACTER SET latin1 COLLATE latin1_bin PRIMARY KEY,n INT) PARTITION BY LIST COLUMNS(v)(PARTITION p VALUES IN(_latin1 X'E9','a  '),PARTITION q VALUES IN('z'))"
            ),
            .init("INSERT INTO ddlcompat.s VALUES(_latin1 X'E9',1),('a',2),('z',3)"),
            .init(
                "CREATE TABLE ddlcompat.d(d DATE NOT NULL,id INT NOT NULL,PRIMARY KEY(d,id)) PARTITION BY RANGE COLUMNS(d,id)(PARTITION p VALUES LESS THAN('20260101',10),PARTITION q VALUES LESS THAN(MAXVALUE,MAXVALUE))"
            ),
            .init(
                "INSERT INTO ddlcompat.d VALUES('2026-01-01',9),('2026-01-01',10)", phaseEnd: "move-and-create-bounds"),
            .init("DELETE FROM ddlcompat.t WHERE v=X'FF'", restartBefore: true),
            .init(
                "SET character_set_connection=latin1; CREATE TABLE ddlcompat.encoded(v VARBINARY(10) PRIMARY KEY) PARTITION BY LIST COLUMNS(v)(PARTITION p VALUES IN('é',_latin1 'é'))"
            ),
            .init("INSERT INTO ddlcompat.encoded VALUES(X'E9'),(X'C3A9')"),
            .init(
                "CREATE TABLE ddlcompat.b(v VARBINARY(10) PRIMARY KEY) PARTITION BY LIST COLUMNS(v)(PARTITION p VALUES IN(X'005C0A27',X'FF',X'',X'2A2F'))"
            ),
            .init("INSERT INTO ddlcompat.b VALUES(X'005C0A27'),(X'FF'),(X''),(X'2A2F')"),
            .init(
                "CREATE TABLE ddlcompat.pb_seed(v VARBINARY(10) PRIMARY KEY,n INT) PARTITION BY RANGE COLUMNS(v)(PARTITION p VALUES LESS THAN(X'80FF'),PARTITION q VALUES LESS THAN(MAXVALUE))"
            ),
            .init("INSERT INTO ddlcompat.pb_seed VALUES(X'0080',1),(X'80FE',2),(X'80FF',3),(X'FF',4)"),
            .init(
                "CREATE TABLE ddlcompat.pb_reorganized(v VARBINARY(10) PRIMARY KEY,n INT) PARTITION BY RANGE COLUMNS(v)(PARTITION p VALUES LESS THAN(X'80FF'),PARTITION q VALUES LESS THAN(MAXVALUE))"
            ),
            .init("INSERT INTO ddlcompat.pb_reorganized VALUES(X'0080',1),(X'80FE',2),(X'80FF',3),(X'FF',4)"),
            .init(
                "ALTER TABLE ddlcompat.pb_reorganized REORGANIZE PARTITION q INTO(PARTITION middle VALUES LESS THAN(_binary X'F0'),PARTITION q VALUES LESS THAN(MAXVALUE))"
            ),
            .init(
                "CREATE TABLE ddlcompat.pb_moved(v VARBINARY(10) PRIMARY KEY,n INT) PARTITION BY RANGE COLUMNS(v)(PARTITION p VALUES LESS THAN(X'80FF'),PARTITION q VALUES LESS THAN(MAXVALUE))"
            ),
            .init("INSERT INTO ddlcompat.pb_moved VALUES(X'0080',1),(X'80FE',2),(X'80FF',3),(X'FF',4)"),
            .init(
                "ALTER TABLE ddlcompat.pb_moved REORGANIZE PARTITION q INTO(PARTITION middle VALUES LESS THAN(_binary X'F0'),PARTITION q VALUES LESS THAN(MAXVALUE))"
            ),
            .init("UPDATE ddlcompat.pb_moved SET v=X'81' WHERE v=X'80FE'", phaseEnd: "delete-and-retain-results"),
        ], nativeInnoDB: true,
        finalObservations: .init(
            checks: [
                .init(
                    id: "binary-low-rows",
                    check: .init("SELECT HEX(v),n FROM ddlcompat.pb_seed PARTITION(p) ORDER BY v", "0080\t1\n80FE\t2")),
                .init(
                    id: "binary-moved-rows",
                    check: .init(
                        "SELECT HEX(v),n FROM ddlcompat.pb_moved PARTITION(middle) ORDER BY v", "80FF\t3\n81\t2")),
                .init(
                    id: "latin1-list-routing",
                    check: .init("SELECT HEX(v),n FROM ddlcompat.s PARTITION(p) ORDER BY v", "61\t2\nE9\t1")),
                .init(id: "tuple-below-bound", check: .init("SELECT id FROM ddlcompat.d PARTITION(p)", "9")),
                .init(id: "tuple-at-bound", check: .init("SELECT id FROM ddlcompat.d PARTITION(q)", "10")),
                .init(
                    id: "final-binary-rows",
                    check: .init("SELECT HEX(v),n FROM ddlcompat.t ORDER BY v", "0080\t1\n80FF\t3\n81\t2")),
                .init(
                    id: "connection-encoded-bytes",
                    check: .init("SELECT HEX(v) FROM ddlcompat.encoded ORDER BY v", "C3A9\nE9")),
                .init(
                    id: "binary-literal-lengths",
                    check: .init(
                        "SELECT LENGTH(v),HEX(v) FROM ddlcompat.b ORDER BY v", "0\t\n4\t005C0A27\n2\t2A2F\n1\tFF")),
                .init(
                    id: "binary-seed-rows",
                    check: .init(
                        "SELECT HEX(v),n FROM ddlcompat.pb_seed ORDER BY v", "0080\t1\n80FE\t2\n80FF\t3\nFF\t4")),
                .init(
                    id: "binary-high-rows",
                    check: .init("SELECT HEX(v),n FROM ddlcompat.pb_seed PARTITION(q) ORDER BY v", "80FF\t3\nFF\t4")),
                .init(
                    id: "reorganized-middle-rows",
                    check: .init(
                        "SELECT HEX(v),n FROM ddlcompat.pb_reorganized PARTITION(middle) ORDER BY v", "80FF\t3")),
                .init(
                    id: "reorganized-high-rows",
                    check: .init("SELECT HEX(v),n FROM ddlcompat.pb_reorganized PARTITION(q) ORDER BY v", "FF\t4")),
                .init(
                    id: "moved-low-rows",
                    check: .init("SELECT HEX(v),n FROM ddlcompat.pb_moved PARTITION(p) ORDER BY v", "0080\t1")),
                .init(
                    id: "rows-before-delete",
                    check: .init("SELECT HEX(v),n FROM ddlcompat.pb_moved ORDER BY v", "0080\t1\n80FF\t3\n81\t2\nFF\t4")
                ),
                .init(
                    id: "deleted-high-partition-empty",
                    check: .init("SELECT COUNT(*) FROM ddlcompat.t PARTITION(q)", "0")),
                .init(
                    id: "latin1-other-partition",
                    check: .init("SELECT HEX(v),n FROM ddlcompat.s PARTITION(q) ORDER BY v", "7A\t3")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.pb_seed,ddlcompat.pb_reorganized,ddlcompat.pb_moved"]
        ))

}
