import Foundation

extension DDLCompatibilityCases {
    static let columnDefinitions = Case(
        "types", "Column definitions, defaults and automatic DATETIME values",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, tiny TINYINT DEFAULT -7, small SMALLINT, medium MEDIUMINT, amount DECIMAL(12,3) NOT NULL DEFAULT 1.25, note TEXT, payload MEDIUMBLOB, dt DATETIME(6), ts TIMESTAMP NULL DEFAULT NULL, tm TIME(3), y YEAR DEFAULT 0, e ENUM('a','b') NOT NULL, s SET('x','y'), v VARCHAR(20) DEFAULT 'hello', normalized INT DEFAULT '0007', fixed BINARY(5) DEFAULT 'hi', UNIQUE KEY lookup(v), KEY by_amount(amount,id)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.t(note,payload,dt,ts,tm,y,s) VALUES('first',0x00ff,'2026-01-02 03:04:05.123456','2026-01-02 03:04:05','-12:30:20.123',2026,'x,y')"
            ),
            .init(
                "SET SESSION timestamp=1700000000.123456; ALTER TABLE ddlcompat.t ADD observed DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)"
            ),
            .init("UPDATE ddlcompat.t SET amount=42.125,note='changed',v='next' WHERE id=1"),
            .init("DELETE FROM ddlcompat.t WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.cd_initial(id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, tiny TINYINT DEFAULT -7, small SMALLINT, medium MEDIUMINT, amount DECIMAL(12,3) NOT NULL DEFAULT 1.25, note TEXT, payload MEDIUMBLOB, dt DATETIME(6), ts TIMESTAMP NULL DEFAULT NULL, tm TIME(3), y YEAR DEFAULT 0, e ENUM('a','b') NOT NULL, s SET('x','y'), v VARCHAR(20) DEFAULT 'hello', normalized INT DEFAULT '0007', fixed BINARY(5) DEFAULT 'hi', UNIQUE KEY lookup(v), KEY by_amount(amount,id)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.cd_initial(note,payload,dt,ts,tm,y,s) VALUES('first',0x00ff,'2026-01-02 03:04:05.123456','2026-01-02 03:04:05','-12:30:20.123',2026,'x,y')"
            ),
            .init(
                "CREATE TABLE ddlcompat.cd_observed(id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, tiny TINYINT DEFAULT -7, small SMALLINT, medium MEDIUMINT, amount DECIMAL(12,3) NOT NULL DEFAULT 1.25, note TEXT, payload MEDIUMBLOB, dt DATETIME(6), ts TIMESTAMP NULL DEFAULT NULL, tm TIME(3), y YEAR DEFAULT 0, e ENUM('a','b') NOT NULL, s SET('x','y'), v VARCHAR(20) DEFAULT 'hello', normalized INT DEFAULT '0007', fixed BINARY(5) DEFAULT 'hi', UNIQUE KEY lookup(v), KEY by_amount(amount,id)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.cd_observed(note,payload,dt,ts,tm,y,s) VALUES('first',0x00ff,'2026-01-02 03:04:05.123456','2026-01-02 03:04:05','-12:30:20.123',2026,'x,y')"
            ),
            .init(
                "SET SESSION timestamp=1700000000.123456; ALTER TABLE ddlcompat.cd_observed ADD observed DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)"
            ),
            .init(
                "CREATE TABLE ddlcompat.cd_updated(id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, tiny TINYINT DEFAULT -7, small SMALLINT, medium MEDIUMINT, amount DECIMAL(12,3) NOT NULL DEFAULT 1.25, note TEXT, payload MEDIUMBLOB, dt DATETIME(6), ts TIMESTAMP NULL DEFAULT NULL, tm TIME(3), y YEAR DEFAULT 0, e ENUM('a','b') NOT NULL, s SET('x','y'), v VARCHAR(20) DEFAULT 'hello', normalized INT DEFAULT '0007', fixed BINARY(5) DEFAULT 'hi', UNIQUE KEY lookup(v), KEY by_amount(amount,id)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init(
                "INSERT INTO ddlcompat.cd_updated(note,payload,dt,ts,tm,y,s) VALUES('first',0x00ff,'2026-01-02 03:04:05.123456','2026-01-02 03:04:05','-12:30:20.123',2026,'x,y')"
            ),
            .init(
                "SET SESSION timestamp=1700000000.123456; ALTER TABLE ddlcompat.cd_updated ADD observed DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)"
            ),
            .init(
                "UPDATE ddlcompat.cd_updated SET amount=42.125,note='changed',v='next' WHERE id=1",
                phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "initial-defaults-and-bytes",
                    check: .init(
                        "SELECT id,tiny,amount,HEX(payload),e,s,v FROM ddlcompat.cd_initial",
                        "1\t-7\t1.250\t00FF\ta\tx,y\thello")),
                .init(
                    id: "timestamp-add-and-normalized-defaults",
                    check: .init(
                        "SELECT CAST(observed AS CHAR),normalized,HEX(fixed) FROM ddlcompat.cd_observed",
                        "2023-11-14 22:13:20.123456\t7\t6869000000")),
                .init(
                    id: "automatic-datetime-definition",
                    check: .init(
                        "SELECT DATETIME_PRECISION,LOWER(COLUMN_DEFAULT)='current_timestamp(6)',LOWER(EXTRA) LIKE '%on update current_timestamp(6)%' FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cd_observed' AND COLUMN_NAME='observed'",
                        "6\t1\t1")),
                .init(
                    id: "updated-row",
                    check: .init("SELECT id,amount,note,v FROM ddlcompat.cd_updated", "1\t42.125\tchanged\tnext")),
                .init(
                    id: "automatic-datetime-updated",
                    check: .init("SELECT observed <> '2023-11-14 22:13:20.123456' FROM ddlcompat.cd_updated", "1")),
                .init(id: "original-row-deleted", check: .init("SELECT COUNT(*) FROM ddlcompat.t", "0")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.cd_initial,ddlcompat.cd_observed,ddlcompat.cd_updated"]))
    static let compoundColumnAlter = Case(
        "alter", "ALTER TABLE: compound column and primary-key changes",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,label VARCHAR(20) DEFAULT 'seed',KEY by_label(label)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.t(id) VALUES(1)"),
            .init(
                "ALTER TABLE ddlcompat.t ADD amount DECIMAL(10,2) NOT NULL DEFAULT -2.50, CHANGE label caption VARCHAR(40) DEFAULT 'renamed', ALTER COLUMN id SET DEFAULT 10, ADD KEY by_amount(amount), ALGORITHM=COPY, LOCK=EXCLUSIVE"
            ),
            .init("INSERT INTO ddlcompat.t(id) VALUES(2)"),
            .init(
                "ALTER TABLE ddlcompat.t ADD report_date DATE NOT NULL DEFAULT '2026-01-01', DROP PRIMARY KEY, ADD PRIMARY KEY(report_date,id)"
            ),
            .init("UPDATE ddlcompat.t SET report_date='2026-02-01',caption='moved' WHERE id=2"),
            .init("ALTER TABLE ddlcompat.t DROP COLUMN caption, ALTER COLUMN amount DROP DEFAULT"),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init(
                "CREATE TABLE ddlcompat.ca_initial(id INT PRIMARY KEY,label VARCHAR(20) DEFAULT 'seed',KEY by_label(label)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ca_initial(id) VALUES(1)"),
            .init(
                "CREATE TABLE ddlcompat.ca_added(id INT PRIMARY KEY,label VARCHAR(20) DEFAULT 'seed',KEY by_label(label)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ca_added(id) VALUES(1)"),
            .init(
                "ALTER TABLE ddlcompat.ca_added ADD amount DECIMAL(10,2) NOT NULL DEFAULT -2.50, CHANGE label caption VARCHAR(40) DEFAULT 'renamed', ALTER COLUMN id SET DEFAULT 10, ADD KEY by_amount(amount), ALGORITHM=COPY, LOCK=EXCLUSIVE"
            ),
            .init("INSERT INTO ddlcompat.ca_added(id) VALUES(2)"),
            .init(
                "CREATE TABLE ddlcompat.ca_moved(id INT PRIMARY KEY,label VARCHAR(20) DEFAULT 'seed',KEY by_label(label)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"
            ),
            .init("INSERT INTO ddlcompat.ca_moved(id) VALUES(1)"),
            .init(
                "ALTER TABLE ddlcompat.ca_moved ADD amount DECIMAL(10,2) NOT NULL DEFAULT -2.50, CHANGE label caption VARCHAR(40) DEFAULT 'renamed', ALTER COLUMN id SET DEFAULT 10, ADD KEY by_amount(amount), ALGORITHM=COPY, LOCK=EXCLUSIVE"
            ),
            .init("INSERT INTO ddlcompat.ca_moved(id) VALUES(2)"),
            .init(
                "ALTER TABLE ddlcompat.ca_moved ADD report_date DATE NOT NULL DEFAULT '2026-01-01', DROP PRIMARY KEY, ADD PRIMARY KEY(report_date,id)"
            ),
            .init(
                "UPDATE ddlcompat.ca_moved SET report_date='2026-02-01',caption='moved' WHERE id=2",
                phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "initial-row-and-default", check: .init("SELECT id,label FROM ddlcompat.ca_initial", "1\tseed")),
                .init(
                    id: "compound-alter-and-default-insert",
                    check: .init(
                        "SELECT id,caption,amount FROM ddlcompat.ca_added ORDER BY id",
                        "1\tseed\t-2.50\n2\trenamed\t-2.50")),
                .init(
                    id: "compound-alter-id-default",
                    check: .init(
                        "SELECT COLUMN_DEFAULT FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ca_added' AND COLUMN_NAME='id'",
                        "10")),
                .init(
                    id: "renamed-and-added-indexes",
                    check: .init(
                        "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ca_added' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                        "PRIMARY\tid\nby_amount\tamount\nby_label\tcaption")),
                .init(
                    id: "composite-key-update",
                    check: .init(
                        "SELECT report_date,id,caption FROM ddlcompat.ca_moved ORDER BY id",
                        "2026-01-01\t1\tseed\n2026-02-01\t2\tmoved")),
                .init(
                    id: "composite-key-order",
                    check: .init(
                        "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ca_moved' AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX",
                        "report_date\nid")),
                .init(
                    id: "drop-column-and-delete",
                    check: .init("SELECT report_date,id,amount FROM ddlcompat.t ORDER BY id", "2026-01-01\t1\t-2.50")),
                .init(
                    id: "amount-default-removed",
                    check: .init(
                        "SELECT COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='amount'",
                        "1")),
                .init(
                    id: "caption-removed",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='caption'",
                        "0")),
                .init(
                    id: "dependent-index-removed",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND INDEX_NAME='by_label'",
                        "0")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.ca_initial,ddlcompat.ca_added,ddlcompat.ca_moved"]))
}
