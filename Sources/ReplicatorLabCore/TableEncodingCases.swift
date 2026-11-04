import Foundation

extension DDLCompatibilityCases {
    static let compoundCharset = Case(
        "compound-charset", "Column character set conversion: compound CONVERT and table defaults",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,v VARCHAR(20) DEFAULT 'café') DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("INSERT INTO ddlcompat.t(id) VALUES(1)"),
            .init(
                "ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, DEFAULT COLLATE utf8mb4_general_ci, ADD n VARCHAR(20) DEFAULT 'new'",
                phaseEnd: "convert-and-set-table-default"),
            .init("ALTER TABLE ddlcompat.t ADD follows VARCHAR(20) DEFAULT 'later'", restartBefore: true),
            .init("INSERT INTO ddlcompat.t(id) VALUES(2)", phaseEnd: "add-inheriting-column-and-insert"),
            .init("UPDATE ddlcompat.t SET v='été',n='café' WHERE id=1", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init(
                "CREATE TABLE ddlcompat.cc_after_convert(id INT PRIMARY KEY,v VARCHAR(20) DEFAULT 'café') DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("INSERT INTO ddlcompat.cc_after_convert(id) VALUES(1)"),
            .init(
                "ALTER TABLE ddlcompat.cc_after_convert CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, DEFAULT COLLATE utf8mb4_general_ci, ADD n VARCHAR(20) DEFAULT 'new'",
                phaseEnd: "update-delete-and-retain-conversion"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "table-default-after-convert",
                    check: .init(
                        "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "utf8mb4_general_ci")),
                .init(
                    id: "converted-column-collations",
                    check: .init(
                        "SELECT COLUMN_NAME,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cc_after_convert' AND COLLATION_NAME IS NOT NULL ORDER BY ORDINAL_POSITION",
                        "v\tutf8mb4_bin\nn\tutf8mb4_bin")),
                .init(
                    id: "later-column-inherits-default",
                    check: .init(
                        "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='follows'",
                        "utf8mb4_general_ci")),
                .init(
                    id: "final-row-bytes",
                    check: .init(
                        "SELECT id,HEX(v),HEX(n),HEX(follows) FROM ddlcompat.t ORDER BY id",
                        "1\tC3A974C3A9\t636166C3A9\t6C61746572")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.cc_after_convert"]
        ))
    static let charsetDefaults = Case(
        "charset-defaults",
        "Database and table character set defaults: MySQL 5.7 DEFAULT syntax",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,v VARCHAR(20)) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"),
            .init("ALTER TABLE ddlcompat.t DEFAULT CHARSET=DEFAULT"),
            .init("ALTER TABLE ddlcompat.t COLLATE latin1_bin, CHARACTER SET DEFAULT"),
            .init("ALTER TABLE ddlcompat.t COLLATE DEFAULT"),
            .init("ALTER TABLE ddlcompat.t CHARACTER SET latin1 COLLATE DEFAULT", phaseEnd: "table-default-clauses"),
            .init("USE ddlcompat; ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET DEFAULT", restartBefore: true),
            .init(
                "USE ddlcompat; SET SESSION collation_database=latin1_bin; ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET DEFAULT",
                phaseEnd: "convert-database-and-session-defaults"),
            .init("INSERT INTO ddlcompat.t VALUES(1,'café')", phaseEnd: "insert-after-session-reset"),
            .init("UPDATE ddlcompat.t SET v='été' WHERE id=1", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.cd_after_default(id INT PRIMARY KEY,v VARCHAR(20)) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("ALTER TABLE ddlcompat.cd_after_default DEFAULT CHARSET=DEFAULT"),
            .init(
                "CREATE TABLE ddlcompat.cd_after_clauses(id INT PRIMARY KEY,v VARCHAR(20)) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("ALTER TABLE ddlcompat.cd_after_clauses DEFAULT CHARSET=DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_clauses COLLATE latin1_bin, CHARACTER SET DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_clauses COLLATE DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_clauses CHARACTER SET latin1 COLLATE DEFAULT"),
            .init(
                "CREATE TABLE ddlcompat.cd_after_utf8(id INT PRIMARY KEY,v VARCHAR(20)) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("ALTER TABLE ddlcompat.cd_after_utf8 DEFAULT CHARSET=DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_utf8 COLLATE latin1_bin, CHARACTER SET DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_utf8 COLLATE DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_utf8 CHARACTER SET latin1 COLLATE DEFAULT"),
            .init(
                "CREATE TABLE ddlcompat.cd_after_insert(id INT PRIMARY KEY,v VARCHAR(20)) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("ALTER TABLE ddlcompat.cd_after_insert DEFAULT CHARSET=DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_insert COLLATE latin1_bin, CHARACTER SET DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_insert COLLATE DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_insert CHARACTER SET latin1 COLLATE DEFAULT"),
            .init(
                "CREATE TABLE ddlcompat.cd_after_update(id INT PRIMARY KEY,v VARCHAR(20)) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("ALTER TABLE ddlcompat.cd_after_update DEFAULT CHARSET=DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_update COLLATE latin1_bin, CHARACTER SET DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_update COLLATE DEFAULT"),
            .init("ALTER TABLE ddlcompat.cd_after_update CHARACTER SET latin1 COLLATE DEFAULT"),
            .init("USE ddlcompat; ALTER TABLE ddlcompat.cd_after_utf8 CONVERT TO CHARACTER SET DEFAULT"),
            .init("USE ddlcompat; ALTER TABLE ddlcompat.cd_after_insert CONVERT TO CHARACTER SET DEFAULT"),
            .init(
                "USE ddlcompat; SET SESSION collation_database=latin1_bin; ALTER TABLE ddlcompat.cd_after_insert CONVERT TO CHARACTER SET DEFAULT"
            ),
            .init("USE ddlcompat; ALTER TABLE ddlcompat.cd_after_update CONVERT TO CHARACTER SET DEFAULT"),
            .init(
                "USE ddlcompat; SET SESSION collation_database=latin1_bin; ALTER TABLE ddlcompat.cd_after_update CONVERT TO CHARACTER SET DEFAULT",
                phaseEnd: "update-delete-and-retain-encoding-states"),
            .init("INSERT INTO ddlcompat.cd_after_insert VALUES(1,'café')"),
            .init("INSERT INTO ddlcompat.cd_after_update VALUES(1,'café')"),
            .init(
                "UPDATE ddlcompat.cd_after_update SET v='été' WHERE id=1", phaseEnd: "retain-insert-and-update-results"),
        ],
        profileExclusions: [.forward: "MySQL 8.4 source rejects DEFAULT as a charset or collation name (error 1064)."],
        finalObservations: .init(
            checks: [
                .init(
                    id: "table-default-inherits-database",
                    check: .init(
                        "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cd_after_default'",
                        "utf8mb4_bin")),
                .init(
                    id: "later-default-clauses-inherit-database",
                    check: .init(
                        "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cd_after_clauses'",
                        "utf8mb4_bin")),
                .init(
                    id: "conversion-uses-database-default",
                    check: .init(
                        "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cd_after_utf8' AND COLUMN_NAME='v'",
                        "utf8mb4_bin")),
                .init(
                    id: "conversion-uses-session-override",
                    check: .init(
                        "SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='v'",
                        "latin1_bin")),
                .init(
                    id: "inserted-row-bytes",
                    check: .init("SELECT id,HEX(v) FROM ddlcompat.cd_after_insert ORDER BY id", "1\t636166E9")),
                .init(
                    id: "updated-row-bytes",
                    check: .init("SELECT id,HEX(v) FROM ddlcompat.cd_after_update ORDER BY id", "1\tE974E9")),
                .init(id: "deleted-original-row", check: .init("SELECT COUNT(*) FROM ddlcompat.t", "0")),
                .init(
                    id: "final-table-collation",
                    check: .init(
                        "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "latin1_bin")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.cd_after_default,ddlcompat.cd_after_clauses,ddlcompat.cd_after_utf8,ddlcompat.cd_after_insert,ddlcompat.cd_after_update"
            ]
        ))
    static let tableCharset = Case(
        "table-charset", "Table character set and collation: defaults, new columns and CREATE TABLE ... LIKE",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,v VARCHAR(20) DEFAULT 'café') DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,'café')"),
            .init(
                "ALTER TABLE ddlcompat.t ADD next_v VARCHAR(20) DEFAULT 'new', DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin",
                phaseEnd: "add-column-before-table-default"),
            .init(
                "ALTER TABLE ddlcompat.t DEFAULT CHARSET=latin1 COLLATE=latin1_bin, ADD last_v VARCHAR(20) DEFAULT 'fin'",
                restartBefore: true),
            .init("UPDATE ddlcompat.t SET v='été',next_v='été',last_v='été' WHERE id=1"),
            .init("ALTER TABLE ddlcompat.t COLLATE=latin1_swedish_ci"),
            .init("CREATE TABLE ddlcompat.copy LIKE ddlcompat.t", phaseEnd: "table-default-before-column-and-like"),
            .init("INSERT INTO ddlcompat.copy(id) VALUES(2)", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.tc_after_default(id INT PRIMARY KEY,v VARCHAR(20) DEFAULT 'café') DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("INSERT INTO ddlcompat.tc_after_default VALUES(1,'café')"),
            .init(
                "ALTER TABLE ddlcompat.tc_after_default ADD next_v VARCHAR(20) DEFAULT 'new', DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "CREATE TABLE ddlcompat.tc_after_update(id INT PRIMARY KEY,v VARCHAR(20) DEFAULT 'café') DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("INSERT INTO ddlcompat.tc_after_update VALUES(1,'café')"),
            .init(
                "ALTER TABLE ddlcompat.tc_after_update ADD next_v VARCHAR(20) DEFAULT 'new', DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "ALTER TABLE ddlcompat.tc_after_update DEFAULT CHARSET=latin1 COLLATE=latin1_bin, ADD last_v VARCHAR(20) DEFAULT 'fin'"
            ),
            .init(
                "UPDATE ddlcompat.tc_after_update SET v='été',next_v='été',last_v='été' WHERE id=1",
                phaseEnd: "insert-copy-delete-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "added-column-collations",
                    check: .init(
                        "SELECT COLUMN_NAME,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='tc_after_default' AND COLLATION_NAME IS NOT NULL ORDER BY ORDINAL_POSITION",
                        "v\tlatin1_bin\nnext_v\tutf8mb4_bin")),
                .init(
                    id: "added-column-row-bytes",
                    check: .init("SELECT HEX(v),HEX(next_v) FROM ddlcompat.tc_after_default", "636166E9\t6E6577")),
                .init(
                    id: "updated-row-bytes",
                    check: .init(
                        "SELECT HEX(v),HEX(next_v),HEX(last_v) FROM ddlcompat.tc_after_update",
                        "E974E9\tC3A974C3A9\tE974E9")),
                .init(
                    id: "like-table-collation",
                    check: .init(
                        "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='copy'",
                        "latin1_swedish_ci")),
                .init(
                    id: "final-table-collation",
                    check: .init(
                        "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'",
                        "latin1_swedish_ci")),
                .init(
                    id: "final-column-collations",
                    check: .init(
                        "SELECT COLUMN_NAME,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLLATION_NAME IS NOT NULL ORDER BY ORDINAL_POSITION",
                        "v\tlatin1_bin\nnext_v\tutf8mb4_bin\nlast_v\tlatin1_bin")),
                .init(id: "deleted-original-row", check: .init("SELECT COUNT(*) FROM ddlcompat.t", "0")),
                .init(
                    id: "like-default-row",
                    check: .init(
                        "SELECT id,HEX(v),HEX(next_v),HEX(last_v) FROM ddlcompat.copy ORDER BY id",
                        "2\t636166E9\t6E6577\t66696E")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.tc_after_default,ddlcompat.tc_after_update"]
        ))
    static let charsetConversion = Case(
        "charset-conversion",
        "Column character set conversion: TEXT widening, defaults and binary values",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,v VARCHAR(20) NOT NULL DEFAULT 'café',e ENUM('one','a') DEFAULT 'a',s SET('one','a') DEFAULT 'a',tx TEXT,small_tx TINYTEXT,b VARBINARY(8),g VARCHAR(20) AS (v) STORED,KEY by_v(v(8))) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init("INSERT INTO ddlcompat.t(id,e,s,tx,small_tx,b) VALUES(1,'one','one,a','été','café',X'00FF')"),
            .init(
                "ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                phaseEnd: "convert-latin1-to-utf8"),
            .init("INSERT INTO ddlcompat.t(id) VALUES(2)", restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t ADD added VARCHAR(10) CHARACTER SET latin1 DEFAULT 'new', CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            ),
            .init(
                "UPDATE ddlcompat.t SET v='été',tx='café',added='é' WHERE id=1", phaseEnd: "insert-defaults-and-update"),
            .init("ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET binary", restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                phaseEnd: "convert-to-binary-and-set-utf8-default"),
            .init("UPDATE ddlcompat.t SET v=X'00FF',tx=X'FE',b=X'FF00' WHERE id=1", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init(
                "CREATE TABLE ddlcompat.cv_after_utf8(id INT PRIMARY KEY,v VARCHAR(20) NOT NULL DEFAULT 'café',e ENUM('one','a') DEFAULT 'a',s SET('one','a') DEFAULT 'a',tx TEXT,small_tx TINYTEXT,b VARBINARY(8),g VARCHAR(20) AS (v) STORED,KEY by_v(v(8))) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.cv_after_utf8(id,e,s,tx,small_tx,b) VALUES(1,'one','one,a','été','café',X'00FF')"
            ),
            .init("ALTER TABLE ddlcompat.cv_after_utf8 CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init(
                "CREATE TABLE ddlcompat.cv_after_defaults(id INT PRIMARY KEY,v VARCHAR(20) NOT NULL DEFAULT 'café',e ENUM('one','a') DEFAULT 'a',s SET('one','a') DEFAULT 'a',tx TEXT,small_tx TINYTEXT,b VARBINARY(8),g VARCHAR(20) AS (v) STORED,KEY by_v(v(8))) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.cv_after_defaults(id,e,s,tx,small_tx,b) VALUES(1,'one','one,a','été','café',X'00FF')"
            ),
            .init("ALTER TABLE ddlcompat.cv_after_defaults CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("INSERT INTO ddlcompat.cv_after_defaults(id) VALUES(2)"),
            .init(
                "CREATE TABLE ddlcompat.cv_after_binary(id INT PRIMARY KEY,v VARCHAR(20) NOT NULL DEFAULT 'café',e ENUM('one','a') DEFAULT 'a',s SET('one','a') DEFAULT 'a',tx TEXT,small_tx TINYTEXT,b VARBINARY(8),g VARCHAR(20) AS (v) STORED,KEY by_v(v(8))) DEFAULT CHARSET=latin1 COLLATE=latin1_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.cv_after_binary(id,e,s,tx,small_tx,b) VALUES(1,'one','one,a','été','café',X'00FF')"
            ),
            .init("ALTER TABLE ddlcompat.cv_after_binary CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("INSERT INTO ddlcompat.cv_after_binary(id) VALUES(2)"),
            .init(
                "ALTER TABLE ddlcompat.cv_after_binary ADD added VARCHAR(10) CHARACTER SET latin1 DEFAULT 'new', CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
            ),
            .init("UPDATE ddlcompat.cv_after_binary SET v='été',tx='café',added='é' WHERE id=1"),
            .init(
                "ALTER TABLE ddlcompat.cv_after_binary CONVERT TO CHARACTER SET binary",
                phaseEnd: "write-binary-values-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "utf8-widened-types",
                    check: .init(
                        "SELECT COLUMN_NAME,DATA_TYPE,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cv_after_utf8' AND COLUMN_NAME IN ('tx','small_tx','b') ORDER BY ORDINAL_POSITION",
                        "tx\tmediumtext\tutf8mb4_bin\nsmall_tx\ttext\tutf8mb4_bin\nb\tvarbinary\tNULL")),
                .init(
                    id: "utf8-row-bytes",
                    check: .init(
                        "SELECT HEX(v),HEX(e),HEX(s),HEX(tx),HEX(b),HEX(g) FROM ddlcompat.cv_after_utf8",
                        "636166C3A9\t6F6E65\t6F6E652C61\tC3A974C3A9\t00FF\t636166C3A9")),
                .init(
                    id: "utf8-inserted-defaults",
                    check: .init("SELECT HEX(v),e,s FROM ddlcompat.cv_after_defaults WHERE id=2", "636166C3A9\ta\ta")),
                .init(
                    id: "binary-column-types",
                    check: .init(
                        "SELECT COLUMN_NAME,DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cv_after_binary' AND COLUMN_NAME IN ('v','tx','small_tx') ORDER BY ORDINAL_POSITION",
                        "v\tvarbinary\ntx\tmediumblob\nsmall_tx\tblob")),
                .init(
                    id: "binary-row-bytes",
                    check: .init(
                        "SELECT HEX(v),HEX(tx),HEX(b),HEX(g) FROM ddlcompat.cv_after_binary WHERE id=1",
                        "C3A974C3A9\t636166C3A9\t00FF\tC3A974C3A9")),
                .init(
                    id: "final-binary-row-bytes",
                    check: .init(
                        "SELECT HEX(v),HEX(tx),HEX(b),HEX(g) FROM ddlcompat.t WHERE id=1", "00FF\tFE\tFF00\t00FF")),
                .init(
                    id: "final-binary-column-types",
                    check: .init(
                        "SELECT COLUMN_NAME,DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME IN ('v','tx','small_tx') ORDER BY ORDINAL_POSITION",
                        "v\tvarbinary\ntx\tmediumblob\nsmall_tx\tblob")),
                .init(id: "deleted-second-row", check: .init("SELECT COUNT(*) FROM ddlcompat.t WHERE id=2", "0")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.cv_after_utf8,ddlcompat.cv_after_defaults,ddlcompat.cv_after_binary"]
        ))
}
