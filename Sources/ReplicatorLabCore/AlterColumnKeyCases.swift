import Foundation

extension DDLCompatibilityCases {
    static let alterColumnKeys = Case(
        "alter-column-keys", "ALTER TABLE: primary keys and AUTO_INCREMENT columns",
        [
            // Keep the original sequence first so replay and restart positions do not move.
            .init("CREATE TABLE ddlcompat.t(v INT)"),
            .init("INSERT INTO ddlcompat.t VALUES(7)"),
            .init("ALTER TABLE ddlcompat.t ADD id INT PRIMARY KEY FIRST"),
            .init("UPDATE ddlcompat.t SET id=1,v=8 WHERE id=0"),
            .init("ALTER TABLE ddlcompat.t ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL"),
            .init("ALTER TABLE ddlcompat.t MODIFY id BIGINT PRIMARY KEY,DROP PRIMARY KEY"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE id k BIGINT PRIMARY KEY AFTER v,DROP PRIMARY KEY",
                phaseEnd: "before-restart-1"),
            .init("UPDATE ddlcompat.t SET k=2,n=9,s='x' WHERE k=1", restartBefore: true),
            .init(
                "SET SESSION auto_increment_increment=3,auto_increment_offset=2; ALTER TABLE ddlcompat.t ADD aid INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST,DROP PRIMARY KEY,ALGORITHM=COPY"
            ),
            .init("INSERT INTO ddlcompat.t(k,v,n,s) VALUES(3,10,11,'y')", phaseEnd: "before-restart-2"),
            .init("UPDATE ddlcompat.t SET v=12 WHERE aid=5", restartBefore: true),
            .init("DELETE FROM ddlcompat.t WHERE aid=2"),
            .init("CREATE TABLE ddlcompat.e(v INT)"),
            .init("ALTER TABLE ddlcompat.e ADD id BIGINT AUTO_INCREMENT PRIMARY KEY FIRST"),
            .init("INSERT INTO ddlcompat.e(v) VALUES(20),(30)"),
            .init("CREATE TABLE ddlcompat.u(id INT PRIMARY KEY,v INT)"),
            .init("INSERT INTO ddlcompat.u VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.u ADD KEY by_seq(seq),ADD seq INT NOT NULL AUTO_INCREMENT"),
            .init(
                "ALTER TABLE ddlcompat.u ADD PRIMARY KEY(seq),DROP PRIMARY KEY,DROP INDEX by_seq",
                phaseEnd: "before-restart-3"),
            .init("UPDATE ddlcompat.u SET v=21 WHERE seq=2", restartBefore: true),
            .init("DELETE FROM ddlcompat.u WHERE seq=1"),
            .init("CREATE TABLE ddlcompat.c(v INT)"),
            .init("ALTER TABLE ddlcompat.c ADD PRIMARY KEY(id),ADD id INT NOT NULL AUTO_INCREMENT"),
            .init("INSERT INTO ddlcompat.c(v) VALUES(40)"),
            .init("DROP TABLE ddlcompat.t,ddlcompat.e,ddlcompat.u,ddlcompat.c"),
            // Retain each compared state by executing its original table operations.
            .init("CREATE TABLE ddlcompat.ak_implicit_key(v INT)"),
            .init("INSERT INTO ddlcompat.ak_implicit_key VALUES(7)"),
            .init("ALTER TABLE ddlcompat.ak_implicit_key ADD id INT PRIMARY KEY FIRST"),
            .init("CREATE TABLE ddlcompat.ak_implicit_defaults(v INT)"),
            .init("INSERT INTO ddlcompat.ak_implicit_defaults VALUES(7)"),
            .init("ALTER TABLE ddlcompat.ak_implicit_defaults ADD id INT PRIMARY KEY FIRST"),
            .init("UPDATE ddlcompat.ak_implicit_defaults SET id=1,v=8 WHERE id=0"),
            .init("ALTER TABLE ddlcompat.ak_implicit_defaults ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL"),
            .init("CREATE TABLE ddlcompat.ak_modified_key(v INT)"),
            .init("INSERT INTO ddlcompat.ak_modified_key VALUES(7)"),
            .init("ALTER TABLE ddlcompat.ak_modified_key ADD id INT PRIMARY KEY FIRST"),
            .init("UPDATE ddlcompat.ak_modified_key SET id=1,v=8 WHERE id=0"),
            .init("ALTER TABLE ddlcompat.ak_modified_key ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL"),
            .init("ALTER TABLE ddlcompat.ak_modified_key MODIFY id BIGINT PRIMARY KEY,DROP PRIMARY KEY"),
            .init("CREATE TABLE ddlcompat.ak_renamed_key(v INT)"),
            .init("INSERT INTO ddlcompat.ak_renamed_key VALUES(7)"),
            .init("ALTER TABLE ddlcompat.ak_renamed_key ADD id INT PRIMARY KEY FIRST"),
            .init("UPDATE ddlcompat.ak_renamed_key SET id=1,v=8 WHERE id=0"),
            .init("ALTER TABLE ddlcompat.ak_renamed_key ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL"),
            .init("ALTER TABLE ddlcompat.ak_renamed_key MODIFY id BIGINT PRIMARY KEY,DROP PRIMARY KEY"),
            .init("ALTER TABLE ddlcompat.ak_renamed_key CHANGE id k BIGINT PRIMARY KEY AFTER v,DROP PRIMARY KEY"),
            .init("CREATE TABLE ddlcompat.ak_renamed_write(v INT)"),
            .init("INSERT INTO ddlcompat.ak_renamed_write VALUES(7)"),
            .init("ALTER TABLE ddlcompat.ak_renamed_write ADD id INT PRIMARY KEY FIRST"),
            .init("UPDATE ddlcompat.ak_renamed_write SET id=1,v=8 WHERE id=0"),
            .init("ALTER TABLE ddlcompat.ak_renamed_write ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL"),
            .init("ALTER TABLE ddlcompat.ak_renamed_write MODIFY id BIGINT PRIMARY KEY,DROP PRIMARY KEY"),
            .init("ALTER TABLE ddlcompat.ak_renamed_write CHANGE id k BIGINT PRIMARY KEY AFTER v,DROP PRIMARY KEY"),
            .init("UPDATE ddlcompat.ak_renamed_write SET k=2,n=9,s='x' WHERE k=1"),
            .init("CREATE TABLE ddlcompat.ak_rebuilt(v INT)"),
            .init("INSERT INTO ddlcompat.ak_rebuilt VALUES(7)"),
            .init("ALTER TABLE ddlcompat.ak_rebuilt ADD id INT PRIMARY KEY FIRST"),
            .init("UPDATE ddlcompat.ak_rebuilt SET id=1,v=8 WHERE id=0"),
            .init("ALTER TABLE ddlcompat.ak_rebuilt ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL"),
            .init("ALTER TABLE ddlcompat.ak_rebuilt MODIFY id BIGINT PRIMARY KEY,DROP PRIMARY KEY"),
            .init("ALTER TABLE ddlcompat.ak_rebuilt CHANGE id k BIGINT PRIMARY KEY AFTER v,DROP PRIMARY KEY"),
            .init("UPDATE ddlcompat.ak_rebuilt SET k=2,n=9,s='x' WHERE k=1"),
            .init(
                "SET SESSION auto_increment_increment=3,auto_increment_offset=2; ALTER TABLE ddlcompat.ak_rebuilt ADD aid INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST,DROP PRIMARY KEY,ALGORITHM=COPY"
            ),
            .init("CREATE TABLE ddlcompat.ak_inserted(v INT)"),
            .init("INSERT INTO ddlcompat.ak_inserted VALUES(7)"),
            .init("ALTER TABLE ddlcompat.ak_inserted ADD id INT PRIMARY KEY FIRST"),
            .init("UPDATE ddlcompat.ak_inserted SET id=1,v=8 WHERE id=0"),
            .init("ALTER TABLE ddlcompat.ak_inserted ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL"),
            .init("ALTER TABLE ddlcompat.ak_inserted MODIFY id BIGINT PRIMARY KEY,DROP PRIMARY KEY"),
            .init("ALTER TABLE ddlcompat.ak_inserted CHANGE id k BIGINT PRIMARY KEY AFTER v,DROP PRIMARY KEY"),
            .init("UPDATE ddlcompat.ak_inserted SET k=2,n=9,s='x' WHERE k=1"),
            .init(
                "SET SESSION auto_increment_increment=3,auto_increment_offset=2; ALTER TABLE ddlcompat.ak_inserted ADD aid INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST,DROP PRIMARY KEY,ALGORITHM=COPY"
            ),
            .init("INSERT INTO ddlcompat.ak_inserted(k,v,n,s) VALUES(3,10,11,'y')"),
            .init("CREATE TABLE ddlcompat.ak_deleted(v INT)"),
            .init("INSERT INTO ddlcompat.ak_deleted VALUES(7)"),
            .init("ALTER TABLE ddlcompat.ak_deleted ADD id INT PRIMARY KEY FIRST"),
            .init("UPDATE ddlcompat.ak_deleted SET id=1,v=8 WHERE id=0"),
            .init("ALTER TABLE ddlcompat.ak_deleted ADD n INT NOT NULL,ADD s VARCHAR(10) NOT NULL"),
            .init("ALTER TABLE ddlcompat.ak_deleted MODIFY id BIGINT PRIMARY KEY,DROP PRIMARY KEY"),
            .init("ALTER TABLE ddlcompat.ak_deleted CHANGE id k BIGINT PRIMARY KEY AFTER v,DROP PRIMARY KEY"),
            .init("UPDATE ddlcompat.ak_deleted SET k=2,n=9,s='x' WHERE k=1"),
            .init(
                "SET SESSION auto_increment_increment=3,auto_increment_offset=2; ALTER TABLE ddlcompat.ak_deleted ADD aid INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST,DROP PRIMARY KEY,ALGORITHM=COPY"
            ),
            .init("INSERT INTO ddlcompat.ak_deleted(k,v,n,s) VALUES(3,10,11,'y')"),
            .init("UPDATE ddlcompat.ak_deleted SET v=12 WHERE aid=5"),
            .init("DELETE FROM ddlcompat.ak_deleted WHERE aid=2"),
            .init("CREATE TABLE ddlcompat.ak_empty(v INT)"),
            .init("ALTER TABLE ddlcompat.ak_empty ADD id BIGINT AUTO_INCREMENT PRIMARY KEY FIRST"),
            .init("INSERT INTO ddlcompat.ak_empty(v) VALUES(20),(30)"),
            .init("CREATE TABLE ddlcompat.ak_secondary(id INT PRIMARY KEY,v INT)"),
            .init("INSERT INTO ddlcompat.ak_secondary VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.ak_secondary ADD KEY by_seq(seq),ADD seq INT NOT NULL AUTO_INCREMENT"),
            .init("CREATE TABLE ddlcompat.ak_promoted(id INT PRIMARY KEY,v INT)"),
            .init("INSERT INTO ddlcompat.ak_promoted VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.ak_promoted ADD KEY by_seq(seq),ADD seq INT NOT NULL AUTO_INCREMENT"),
            .init("ALTER TABLE ddlcompat.ak_promoted ADD PRIMARY KEY(seq),DROP PRIMARY KEY,DROP INDEX by_seq"),
            .init("CREATE TABLE ddlcompat.ak_promoted_write(id INT PRIMARY KEY,v INT)"),
            .init("INSERT INTO ddlcompat.ak_promoted_write VALUES(1,10),(2,20)"),
            .init("ALTER TABLE ddlcompat.ak_promoted_write ADD KEY by_seq(seq),ADD seq INT NOT NULL AUTO_INCREMENT"),
            .init("ALTER TABLE ddlcompat.ak_promoted_write ADD PRIMARY KEY(seq),DROP PRIMARY KEY,DROP INDEX by_seq"),
            .init("UPDATE ddlcompat.ak_promoted_write SET v=21 WHERE seq=2"),
            .init("DELETE FROM ddlcompat.ak_promoted_write WHERE seq=1"),
            .init("CREATE TABLE ddlcompat.ak_grouped(v INT)"),
            .init("ALTER TABLE ddlcompat.ak_grouped ADD PRIMARY KEY(id),ADD id INT NOT NULL AUTO_INCREMENT"),
            .init("INSERT INTO ddlcompat.ak_grouped(v) VALUES(40)", phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(id: "ak-implicit-key-values", check: .init("SELECT id,v FROM ddlcompat.ak_implicit_key", "0\t7")),
                .init(
                    id: "ak-implicit-defaults-values",
                    check: .init("SELECT id,v,n,CONCAT('[',s,']') FROM ddlcompat.ak_implicit_defaults", "1\t8\t0\t[]")),
                .init(
                    id: "ak-implicit-defaults-metadata",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_implicit_defaults' AND COLUMN_NAME IN('n','s') AND IS_NULLABLE='NO' AND COLUMN_DEFAULT IS NULL",
                        "2")),
                .init(
                    id: "ak-renamed-write-values",
                    check: .init("SELECT k,v,n,s FROM ddlcompat.ak_renamed_write", "2\t8\t9\tx")),
                .init(id: "ak-rebuilt-values", check: .init("SELECT aid,k,v FROM ddlcompat.ak_rebuilt", "2\t2\t8")),
                .init(
                    id: "ak-inserted-values",
                    check: .init("SELECT aid,k FROM ddlcompat.ak_inserted ORDER BY aid", "2\t2\n5\t3")),
                .init(
                    id: "ak-empty-values",
                    check: .init("SELECT id,v FROM ddlcompat.ak_empty ORDER BY id", "1\t20\n2\t30")),
                .init(
                    id: "ak-secondary-values",
                    check: .init("SELECT id,seq FROM ddlcompat.ak_secondary ORDER BY id", "1\t1\n2\t2")),
                .init(id: "ak-grouped-values", check: .init("SELECT id,v FROM ddlcompat.ak_grouped", "1\t40")),
                .init(
                    id: "modified-key",
                    check: .init(
                        "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_modified_key' AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX",
                        "id")),
                .init(
                    id: "renamed-column-order",
                    check: .init(
                        "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_renamed_key' ORDER BY ORDINAL_POSITION",
                        "v\nk\nn\ns")),
                .init(
                    id: "renamed-primary-key",
                    check: .init(
                        "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_renamed_key' AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX",
                        "k")),
                .init(
                    id: "auto-increment-update-delete",
                    check: .init("SELECT aid,k,v,n,s FROM ddlcompat.ak_deleted", "5\t3\t12\t11\ty")),
                .init(
                    id: "secondary-auto-increment-key",
                    check: .init(
                        "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_secondary' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                        "PRIMARY\tid\nby_seq\tseq")),
                .init(
                    id: "promoted-primary-key",
                    check: .init(
                        "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ak_promoted' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                        "PRIMARY\tseq")),
                .init(
                    id: "promoted-rows",
                    check: .init("SELECT id,v,seq FROM ddlcompat.ak_promoted ORDER BY id", "1\t10\t1\n2\t20\t2")),
                .init(
                    id: "promoted-key-update-delete",
                    check: .init("SELECT id,v,seq FROM ddlcompat.ak_promoted_write", "2\t21\t2")),
                .init(
                    id: "original-tables-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','e','u','c')",
                        "0")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.ak_implicit_key,ddlcompat.ak_implicit_defaults,ddlcompat.ak_modified_key,ddlcompat.ak_renamed_key,ddlcompat.ak_renamed_write,ddlcompat.ak_rebuilt,ddlcompat.ak_inserted,ddlcompat.ak_deleted,ddlcompat.ak_empty,ddlcompat.ak_secondary,ddlcompat.ak_promoted,ddlcompat.ak_promoted_write,ddlcompat.ak_grouped"
            ]
        ))
}
