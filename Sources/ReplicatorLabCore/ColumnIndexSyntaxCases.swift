import Foundation

extension DDLCompatibilityCases {
    static let columnIndexSyntax = Case(
        "column-index-syntax", "Indexes: column keys, index options and SERIAL",
        [
            // Keep the original sequence first so replay and restart positions do not move.
            .init(
                "CREATE TABLE ddlcompat.t(id INT KEY,a INT UNIQUE,b INT UNIQUE KEY,note VARCHAR(20) COLUMN_FORMAT DYNAMIC STORAGE MEMORY,KEY by_note(note) COMMENT 'lookup' KEY_BLOCK_SIZE=4 USING BTREE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10,20,'first'),(2,11,21,'second')"),
            .init("ALTER TABLE ddlcompat.t ADD COLUMN (c INT DEFAULT 3,d INT,KEY by_c(c)),ADD e INT UNIQUE"),
            .init("UPDATE ddlcompat.t SET c=4,d=5,e=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.t MODIFY a INT UNIQUE", phaseEnd: "before-restart-1"),
            .init("ALTER TABLE ddlcompat.t CHANGE b renamed INT UNIQUE", restartBefore: true),
            .init(
                "CREATE INDEX by_d USING HASH ON ddlcompat.t(d) COMMENT 'online options' ALGORITHM=DEFAULT LOCK=DEFAULT"
            ),
            .init("DROP INDEX by_d ON ddlcompat.t ALGORITHM=DEFAULT LOCK=DEFAULT"),
            .init("ALTER TABLE ddlcompat.t ALGORITHM=COPY"),
            .init("ALTER TABLE ddlcompat.t DROP e RESTRICT,DROP d CASCADE"),
            .init("UPDATE ddlcompat.t SET a=12,renamed=22,c=8 WHERE id=1"),
            .init("CREATE TABLE ddlcompat.s(id SERIAL,v INT UNIQUE)"),
            .init("INSERT INTO ddlcompat.s(v) VALUES(40),(41)", phaseEnd: "before-restart-2"),
            .init("UPDATE ddlcompat.s SET v=42 WHERE id=1", restartBefore: true),
            .init("CREATE TABLE ddlcompat.q(id BIGINT UNSIGNED SERIAL DEFAULT VALUE,v INT)"),
            .init("INSERT INTO ddlcompat.q(v) VALUES(50),(51)"),
            .init("ALTER TABLE ddlcompat.q ADD (extra INT,UNIQUE KEY(extra))"),
            .init("UPDATE ddlcompat.q SET extra=60 WHERE id=1"),
            .init("DELETE FROM ddlcompat.s WHERE id=2"),
            .init("DROP TABLE ddlcompat.t,ddlcompat.s,ddlcompat.q"),
            // Retain each compared state by executing its original table operations.
            .init(
                "CREATE TABLE ddlcompat.ci_inline(id INT KEY,a INT UNIQUE,b INT UNIQUE KEY,note VARCHAR(20) COLUMN_FORMAT DYNAMIC STORAGE MEMORY,KEY by_note(note) COMMENT 'lookup' KEY_BLOCK_SIZE=4 USING BTREE)"
            ),
            .init("INSERT INTO ddlcompat.ci_inline VALUES(1,10,20,'first'),(2,11,21,'second')"),
            .init(
                "CREATE TABLE ddlcompat.ci_grouped(id INT KEY,a INT UNIQUE,b INT UNIQUE KEY,note VARCHAR(20) COLUMN_FORMAT DYNAMIC STORAGE MEMORY,KEY by_note(note) COMMENT 'lookup' KEY_BLOCK_SIZE=4 USING BTREE)"
            ),
            .init("INSERT INTO ddlcompat.ci_grouped VALUES(1,10,20,'first'),(2,11,21,'second')"),
            .init("ALTER TABLE ddlcompat.ci_grouped ADD COLUMN (c INT DEFAULT 3,d INT,KEY by_c(c)),ADD e INT UNIQUE"),
            .init("UPDATE ddlcompat.ci_grouped SET c=4,d=5,e=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.ci_grouped MODIFY a INT UNIQUE"),
            .init(
                "CREATE TABLE ddlcompat.ci_index_created(id INT KEY,a INT UNIQUE,b INT UNIQUE KEY,note VARCHAR(20) COLUMN_FORMAT DYNAMIC STORAGE MEMORY,KEY by_note(note) COMMENT 'lookup' KEY_BLOCK_SIZE=4 USING BTREE)"
            ),
            .init("INSERT INTO ddlcompat.ci_index_created VALUES(1,10,20,'first'),(2,11,21,'second')"),
            .init(
                "ALTER TABLE ddlcompat.ci_index_created ADD COLUMN (c INT DEFAULT 3,d INT,KEY by_c(c)),ADD e INT UNIQUE"
            ),
            .init("UPDATE ddlcompat.ci_index_created SET c=4,d=5,e=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.ci_index_created MODIFY a INT UNIQUE"),
            .init("ALTER TABLE ddlcompat.ci_index_created CHANGE b renamed INT UNIQUE"),
            .init(
                "CREATE INDEX by_d USING HASH ON ddlcompat.ci_index_created(d) COMMENT 'online options' ALGORITHM=DEFAULT LOCK=DEFAULT"
            ),
            .init(
                "CREATE TABLE ddlcompat.ci_index_dropped(id INT KEY,a INT UNIQUE,b INT UNIQUE KEY,note VARCHAR(20) COLUMN_FORMAT DYNAMIC STORAGE MEMORY,KEY by_note(note) COMMENT 'lookup' KEY_BLOCK_SIZE=4 USING BTREE)"
            ),
            .init("INSERT INTO ddlcompat.ci_index_dropped VALUES(1,10,20,'first'),(2,11,21,'second')"),
            .init(
                "ALTER TABLE ddlcompat.ci_index_dropped ADD COLUMN (c INT DEFAULT 3,d INT,KEY by_c(c)),ADD e INT UNIQUE"
            ),
            .init("UPDATE ddlcompat.ci_index_dropped SET c=4,d=5,e=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.ci_index_dropped MODIFY a INT UNIQUE"),
            .init("ALTER TABLE ddlcompat.ci_index_dropped CHANGE b renamed INT UNIQUE"),
            .init(
                "CREATE INDEX by_d USING HASH ON ddlcompat.ci_index_dropped(d) COMMENT 'online options' ALGORITHM=DEFAULT LOCK=DEFAULT"
            ),
            .init("DROP INDEX by_d ON ddlcompat.ci_index_dropped ALGORITHM=DEFAULT LOCK=DEFAULT"),
            .init("ALTER TABLE ddlcompat.ci_index_dropped ALGORITHM=COPY"),
            .init(
                "CREATE TABLE ddlcompat.ci_final(id INT KEY,a INT UNIQUE,b INT UNIQUE KEY,note VARCHAR(20) COLUMN_FORMAT DYNAMIC STORAGE MEMORY,KEY by_note(note) COMMENT 'lookup' KEY_BLOCK_SIZE=4 USING BTREE)"
            ),
            .init("INSERT INTO ddlcompat.ci_final VALUES(1,10,20,'first'),(2,11,21,'second')"),
            .init("ALTER TABLE ddlcompat.ci_final ADD COLUMN (c INT DEFAULT 3,d INT,KEY by_c(c)),ADD e INT UNIQUE"),
            .init("UPDATE ddlcompat.ci_final SET c=4,d=5,e=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.ci_final MODIFY a INT UNIQUE"),
            .init("ALTER TABLE ddlcompat.ci_final CHANGE b renamed INT UNIQUE"),
            .init(
                "CREATE INDEX by_d USING HASH ON ddlcompat.ci_final(d) COMMENT 'online options' ALGORITHM=DEFAULT LOCK=DEFAULT"
            ),
            .init("DROP INDEX by_d ON ddlcompat.ci_final ALGORITHM=DEFAULT LOCK=DEFAULT"),
            .init("ALTER TABLE ddlcompat.ci_final ALGORITHM=COPY"),
            .init("ALTER TABLE ddlcompat.ci_final DROP e RESTRICT,DROP d CASCADE"),
            .init("UPDATE ddlcompat.ci_final SET a=12,renamed=22,c=8 WHERE id=1"),
            .init("CREATE TABLE ddlcompat.ci_serial_seed(id SERIAL,v INT UNIQUE)"),
            .init("INSERT INTO ddlcompat.ci_serial_seed(v) VALUES(40),(41)"),
            .init("CREATE TABLE ddlcompat.ci_serial_updated(id SERIAL,v INT UNIQUE)"),
            .init("INSERT INTO ddlcompat.ci_serial_updated(v) VALUES(40),(41)"),
            .init("UPDATE ddlcompat.ci_serial_updated SET v=42 WHERE id=1"),
            .init("CREATE TABLE ddlcompat.ci_serial_deleted(id SERIAL,v INT UNIQUE)"),
            .init("INSERT INTO ddlcompat.ci_serial_deleted(v) VALUES(40),(41)"),
            .init("UPDATE ddlcompat.ci_serial_deleted SET v=42 WHERE id=1"),
            .init("DELETE FROM ddlcompat.ci_serial_deleted WHERE id=2"),
            .init("CREATE TABLE ddlcompat.ci_serial_default(id BIGINT UNSIGNED SERIAL DEFAULT VALUE,v INT)"),
            .init("INSERT INTO ddlcompat.ci_serial_default(v) VALUES(50),(51)"),
            .init("ALTER TABLE ddlcompat.ci_serial_default ADD (extra INT,UNIQUE KEY(extra))"),
            .init("UPDATE ddlcompat.ci_serial_default SET extra=60 WHERE id=1", phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "ci-grouped-metadata",
                    check: .init(
                        "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ci_grouped' AND COLUMN_NAME='a' ORDER BY INDEX_NAME",
                        "a\na_2")),
                .init(
                    id: "ci-final-values",
                    check: .init(
                        "SELECT id,a,renamed,c FROM ddlcompat.ci_final ORDER BY id", "1\t12\t22\t8\n2\t11\t21\t3")),
                .init(
                    id: "inline-seed-rows",
                    check: .init("SELECT * FROM ddlcompat.ci_inline ORDER BY id", "1\t10\t20\tfirst\n2\t11\t21\tsecond")
                ),
                .init(
                    id: "grouped-defaults",
                    check: .init(
                        "SELECT id,c,d,e FROM ddlcompat.ci_grouped ORDER BY id", "1\t4\t5\t6\n2\t3\tNULL\tNULL")),
                .init(
                    id: "created-index",
                    check: .init(
                        "SELECT COLUMN_NAME,NON_UNIQUE,INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ci_index_created' AND INDEX_NAME='by_d' ORDER BY SEQ_IN_INDEX",
                        "d\t1\tBTREE")),
                .init(
                    id: "dropped-index",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ci_index_dropped' AND INDEX_NAME='by_d'",
                        "0")),
                .init(
                    id: "serial-seed",
                    check: .init("SELECT id,v FROM ddlcompat.ci_serial_seed ORDER BY id", "1\t40\n2\t41")),
                .init(
                    id: "serial-update",
                    check: .init("SELECT id,v FROM ddlcompat.ci_serial_updated ORDER BY id", "1\t42\n2\t41")),
                .init(
                    id: "serial-delete",
                    check: .init("SELECT id,v FROM ddlcompat.ci_serial_deleted ORDER BY id", "1\t42")),
                .init(
                    id: "serial-default-values",
                    check: .init(
                        "SELECT id,v,extra FROM ddlcompat.ci_serial_default ORDER BY id", "1\t50\t60\n2\t51\tNULL")),
                .init(
                    id: "serial-default-unique-key",
                    check: .init(
                        "SELECT COLUMN_NAME,NON_UNIQUE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='ci_serial_default' AND INDEX_NAME='extra' ORDER BY SEQ_IN_INDEX",
                        "extra\t0")),
                .init(
                    id: "original-tables-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','s','q')",
                        "0")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.ci_inline,ddlcompat.ci_grouped,ddlcompat.ci_index_created,ddlcompat.ci_index_dropped,ddlcompat.ci_final,ddlcompat.ci_serial_seed,ddlcompat.ci_serial_updated,ddlcompat.ci_serial_deleted,ddlcompat.ci_serial_default"
            ]
        ))
}
