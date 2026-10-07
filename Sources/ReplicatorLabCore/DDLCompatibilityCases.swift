import Foundation

/// Ordered workloads compare MySQL 8.4, its native replica, and the external
/// applier's MySQL 5.7 MyISAM target after every source statement.
enum DDLCompatibilityCases {
    struct Check {
        let sql: String
        let expected: String
        init(_ sql: String,_ expected: String) { self.sql=sql; self.expected=expected }
    }
    struct Step {
        let sql: String
        let checks: [Check]
        let sql57: String
        var transactions = 1
        init(_ sql: String,_ checks: [Check] = [], sql57: String? = nil) { self.sql=sql; self.checks=checks; self.sql57=sql57 ?? sql }
    }
    struct Case {
        let test: QualificationCase
        let steps: [Step]
        let nativeInnoDB: Bool
        init(_ id: String,_ description: String,_ steps: [Step],nativeInnoDB: Bool = false,file: String = #filePath,line: UInt = #line) {
            test=QualificationCase("ddl-compat-"+id,description,file:file,line:line)
            self.steps=steps; self.nativeInnoDB=nativeInnoDB
        }
    }
    static let cases: [Case] = [
        .init("types","CREATE supported column types, defaults, auto increment, inline keys; follow with DML",[
            .init("CREATE TABLE ddlcompat.t(id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, tiny TINYINT DEFAULT -7, small SMALLINT, medium MEDIUMINT, amount DECIMAL(12,3) NOT NULL DEFAULT 1.25, note TEXT, payload MEDIUMBLOB, dt DATETIME(6), ts TIMESTAMP NULL DEFAULT NULL, tm TIME(3), y YEAR DEFAULT 0, e ENUM('a','b') NOT NULL, s SET('x','y'), v VARCHAR(20) DEFAULT 'hello', normalized INT DEFAULT '0007', fixed BINARY(5) DEFAULT 'hi', UNIQUE KEY lookup(v), KEY by_amount(amount,id)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"),
            .init("INSERT INTO ddlcompat.t(note,payload,dt,ts,tm,y,s) VALUES('first',0x00ff,'2026-01-02 03:04:05.123456','2026-01-02 03:04:05','-12:30:20.123',2026,'x,y')",[.init("SELECT id,tiny,amount,HEX(payload),e,s,v FROM ddlcompat.t","1\t-7\t1.250\t00FF\ta\tx,y\thello")]),
            .init("SET SESSION timestamp=1700000000.123456; ALTER TABLE ddlcompat.t ADD observed DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)",[.init("SELECT CAST(observed AS CHAR),normalized,HEX(fixed) FROM ddlcompat.t","2023-11-14 22:13:20.123456\t7\t6869000000")]),
            .init("UPDATE ddlcompat.t SET amount=42.125,note='changed',v='next' WHERE id=1",[.init("SELECT id,amount,note,v FROM ddlcompat.t","1\t42.125\tchanged\tnext")]),
            .init("DELETE FROM ddlcompat.t WHERE id=1",[.init("SELECT COUNT(*) FROM ddlcompat.t","0")])
        ]),
        .init("alter","Compound ADD/CHANGE/default/index and primary-key changes preserve existing data",[
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,label VARCHAR(20) DEFAULT 'seed',KEY by_label(label)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"),
            .init("INSERT INTO ddlcompat.t(id) VALUES(1)",[]),
            .init("ALTER TABLE ddlcompat.t ADD amount DECIMAL(10,2) NOT NULL DEFAULT -2.50, CHANGE label caption VARCHAR(40) DEFAULT 'renamed', ALTER COLUMN id SET DEFAULT 10, ADD KEY by_amount(amount), ALGORITHM=COPY, LOCK=EXCLUSIVE",[.init("SELECT id,caption,amount FROM ddlcompat.t","1\tseed\t-2.50")]),
            .init("INSERT INTO ddlcompat.t(id) VALUES(2)",[.init("SELECT id,caption,amount FROM ddlcompat.t ORDER BY id","1\tseed\t-2.50\n2\trenamed\t-2.50")]),
            .init("ALTER TABLE ddlcompat.t ADD report_date DATE NOT NULL DEFAULT '2026-01-01', DROP PRIMARY KEY, ADD PRIMARY KEY(report_date,id)"),
            .init("UPDATE ddlcompat.t SET report_date='2026-02-01',caption='moved' WHERE id=2",[.init("SELECT report_date,id,caption FROM ddlcompat.t ORDER BY id","2026-01-01\t1\tseed\n2026-02-01\t2\tmoved")]),
            .init("ALTER TABLE ddlcompat.t DROP COLUMN caption, ALTER COLUMN amount DROP DEFAULT"),
            .init("DELETE FROM ddlcompat.t WHERE id=2",[.init("SELECT COUNT(*) FROM ddlcompat.t","1")])
        ]),
        .init("database","ALTER defaults, DROP retires all table schemas, then recreate and resume DML",[
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n VARCHAR(10))"),
            .init("INSERT INTO ddlcompat.t VALUES(1,'before')"),
            .init("ALTER SCHEMA ddlcompat DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci",[.init("SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t'","utf8mb4_bin")]),
            .init("CREATE TABLE ddlcompat.second(id INT PRIMARY KEY,n VARCHAR(10))",[.init("SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='second'","utf8mb4_general_ci")]),
            .init("DROP DATABASE ddlcompat",[.init("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='ddlcompat'","0")]),
            .init("CREATE SCHEMA ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n DECIMAL(10,2))"),
            .init("INSERT INTO ddlcompat.t VALUES(1,2.50)",[.init("SELECT id,n FROM ddlcompat.t","1\t2.50")])
        ]),
        .init("generated","Stored and virtual generated columns survive multirow INSERT, UPDATE and ALTER",[
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT,doubled INT GENERATED ALWAYS AS (n*2) STORED,added INT AS (n+1) VIRTUAL)"),
            .init("INSERT INTO ddlcompat.t(id,n) VALUES(1,7),(2,NULL)",[.init("SELECT * FROM ddlcompat.t ORDER BY id","1\t7\t14\t8\n2\tNULL\tNULL\tNULL")]),
            .init("UPDATE ddlcompat.t SET n=9 WHERE id=1",[.init("SELECT * FROM ddlcompat.t WHERE id=1","1\t9\t18\t10")]),
            .init("ALTER TABLE ddlcompat.t ADD next_value INT AS (n+2) STORED"),
            .init("INSERT INTO ddlcompat.t(id,n) VALUES(3,11)",[.init("SELECT * FROM ddlcompat.t WHERE id=3","3\t11\t22\t12\t13")]),
            .init("DELETE FROM ddlcompat.t WHERE id=2",[.init("SELECT COUNT(*) FROM ddlcompat.t","2")])
        ]),
        .init("partitions","Partition DDL removes and exchanges data without row-delete events",[
            .init("CREATE TABLE ddlcompat.t(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id)) PARTITION BY RANGE COLUMNS(report_date) (PARTITION old VALUES LESS THAN ('2026-01-01'),PARTITION current_data VALUES LESS THAN ('2027-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"),
            .init("INSERT INTO ddlcompat.t VALUES('2025-06-01',1,10),('2026-06-01',2,20),('2027-06-01',3,30)"),
            .init("ALTER TABLE ddlcompat.t DROP PARTITION old",[.init("SELECT id FROM ddlcompat.t ORDER BY id","2\n3")]),
            .init("ALTER TABLE ddlcompat.t TRUNCATE PARTITION current_data",[.init("SELECT id FROM ddlcompat.t ORDER BY id","3")]),
            .init("ALTER TABLE ddlcompat.t REORGANIZE PARTITION future INTO (PARTITION next_year VALUES LESS THAN ('2028-01-01'),PARTITION future VALUES LESS THAN (MAXVALUE))"),
            .init("CREATE TABLE ddlcompat.stage(report_date DATE NOT NULL,id INT NOT NULL,n INT,PRIMARY KEY(report_date,id))"),
            .init("INSERT INTO ddlcompat.stage VALUES('2027-08-01',4,40)"),
            .init("ALTER TABLE ddlcompat.t EXCHANGE PARTITION next_year WITH TABLE ddlcompat.stage WITH VALIDATION",[.init("SELECT id FROM ddlcompat.t ORDER BY id","4"),.init("SELECT id FROM ddlcompat.stage ORDER BY id","3")]),
            .init("UPDATE ddlcompat.t SET n=41 WHERE report_date='2027-08-01' AND id=4",[.init("SELECT n FROM ddlcompat.t","41")]),
            .init("ALTER TABLE ddlcompat.t REMOVE PARTITIONING",[.init("SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND PARTITION_NAME IS NOT NULL","0")])
        ],nativeInnoDB:true),
        .init("hash-list","HASH/KEY and LIST partition creation and lifecycle",[
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) PARTITION BY HASH(id) PARTITIONS 4"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.t COALESCE PARTITION 2",[.init("SELECT SUM(n) FROM ddlcompat.t","30")]),
            .init("ALTER TABLE ddlcompat.t PARTITION BY KEY(id) PARTITIONS 2"),
            .init("ALTER TABLE ddlcompat.t PARTITION BY LIST(id) (PARTITION p1 VALUES IN (1),PARTITION p2 VALUES IN (2))"),
            .init("ALTER TABLE ddlcompat.t ADD PARTITION (PARTITION p3 VALUES IN (3))"),
            .init("INSERT INTO ddlcompat.t VALUES(3,30)",[.init("SELECT SUM(n) FROM ddlcompat.t","60")])
        ],nativeInnoDB:true),
        .init("views","Create/replace/alter/drop views and apply their base-table row effects",[
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW ddlcompat.v AS SELECT id,n FROM ddlcompat.t"),
            .init("INSERT INTO ddlcompat.v VALUES(1,7)",[.init("SELECT * FROM ddlcompat.v","1\t7")]),
            .init("CREATE OR REPLACE SQL SECURITY INVOKER VIEW ddlcompat.v AS SELECT id,n+1 AS n FROM ddlcompat.t",[.init("SELECT * FROM ddlcompat.v","1\t8")]),
            .init("ALTER SQL SECURITY INVOKER VIEW ddlcompat.v AS SELECT id,n+2 AS n FROM ddlcompat.t",[.init("SELECT * FROM ddlcompat.v","1\t9")]),
            .init("DROP VIEW ddlcompat.v",[.init("SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='ddlcompat'","0")])
        ]),
        .init("routines","Create compound stored procedure and function without executing their bodies",[
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("DELIMITER $$\nCREATE PROCEDURE ddlcompat.p(IN k INT) SQL SECURITY INVOKER BEGIN DECLARE v INT; SET v=k+1; INSERT INTO ddlcompat.t VALUES(k,v); END$$\nDELIMITER ;",[.init("SELECT COUNT(*) FROM ddlcompat.t","0")]),
            .init("CREATE FUNCTION ddlcompat.f(k INT) RETURNS INT DETERMINISTIC NO SQL SQL SECURITY INVOKER RETURN k+1",[.init("SELECT ddlcompat.f(7)","8")]),
            .init("CALL ddlcompat.p(1)",[.init("SELECT * FROM ddlcompat.t","1\t2")]),
            .init("DROP PROCEDURE ddlcompat.p"),
            .init("DROP FUNCTION ddlcompat.f",[.init("SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='ddlcompat'","0")])
        ]),
        .init("temporary","ROW omits temporary operations but keeps permanent effects and expanded CREATE LIKE",[
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("USE ddlcompat; CREATE TEMPORARY TABLE tmp(id INT PRIMARY KEY,n INT); INSERT INTO tmp VALUES(1,7),(2,8); INSERT INTO ddlcompat.t SELECT * FROM tmp; DROP TEMPORARY TABLE tmp",[.init("SELECT * FROM ddlcompat.t ORDER BY id","1\t7\n2\t8")]),
            .init("USE ddlcompat; CREATE TEMPORARY TABLE tmp(id INT PRIMARY KEY,n INT) ENGINE=MyISAM; CREATE TABLE ddlcompat.cloned LIKE tmp; DROP TEMPORARY TABLE tmp",[.init("SELECT COUNT(*) FROM ddlcompat.cloned","0")],sql57:"USE ddlcompat; CREATE TEMPORARY TABLE tmp(id INT PRIMARY KEY,n INT) ENGINE=InnoDB; CREATE TABLE ddlcompat.cloned LIKE tmp; DROP TEMPORARY TABLE tmp"),
            .init("INSERT INTO ddlcompat.cloned VALUES(3,9)",[.init("SELECT * FROM ddlcompat.cloned","3\t9")])
        ])
    ]
    static let collationCleanup = QualificationCase("ddl-compat-collation-cleanup","Translate default and explicit collations through CREATE LIKE, INSERT SELECT, multi-table RENAME and clean restart")
    static let collationCollision = QualificationCase("ddl-compat-collation-collision","Block a NO PAD to PAD SPACE unique-key collision without advancing past the failed group")
    static let trigger = QualificationCase("ddl-compat-reject-trigger","Reject source trigger DDL before target mutation and checkpoint advance")
    static let event = QualificationCase("ddl-compat-reject-event","Reject source event DDL even when disabled on the source")
    static let skipTrigger = QualificationCase("ddl-compat-skip-trigger","Skip CREATE/DROP trigger definitions, audit checkpoints and match native final row effects")
    static let sourceTrigger = QualificationCase("ddl-compat-source-trigger","A preexisting source-only BEFORE trigger produces final row values without target re-firing")
    static let targetTrigger = QualificationCase("ddl-compat-target-trigger","Reject preexisting target triggers before DML")
    static let generatedMismatch = QualificationCase("ddl-compat-generated-mismatch","Block when target-generated values differ from the FULL source row image")
    static var declarations: [QualificationCase] {cases.map(\.test)+[trigger,event,skipTrigger,sourceTrigger,targetTrigger,generatedMismatch,collationCleanup,collationCollision]}
}
