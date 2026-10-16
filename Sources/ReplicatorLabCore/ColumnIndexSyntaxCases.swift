import Foundation

extension DDLCompatibilityCases {
    static let columnIndexSyntax = Case(
        "column-index-syntax", "Inline and grouped keys, index options, native key naming, restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT KEY,a INT UNIQUE,b INT UNIQUE KEY,note VARCHAR(20) COLUMN_FORMAT DYNAMIC STORAGE MEMORY,KEY by_note(note) COMMENT 'lookup' KEY_BLOCK_SIZE=4 USING BTREE)"
            ),
            .init("INSERT INTO ddlcompat.t VALUES(1,10,20,'first'),(2,11,21,'second')"),
            .init(
                "ALTER TABLE ddlcompat.t ADD COLUMN (c INT DEFAULT 3,d INT,KEY by_c(c)),ADD e INT UNIQUE",
                restartBefore: true),
            .init("UPDATE ddlcompat.t SET c=4,d=5,e=6 WHERE id=1"),
            .init(
                "ALTER TABLE ddlcompat.t MODIFY a INT UNIQUE",
                [
                    .init(
                        "SELECT INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND COLUMN_NAME='a' ORDER BY INDEX_NAME",
                        "a\na_2")
                ]),
            .init("ALTER TABLE ddlcompat.t CHANGE b renamed INT UNIQUE", restartBefore: true),
            .init(
                "CREATE INDEX by_d USING HASH ON ddlcompat.t(d) COMMENT 'online options' ALGORITHM=DEFAULT LOCK=DEFAULT"
            ),
            .init("DROP INDEX by_d ON ddlcompat.t ALGORITHM=DEFAULT LOCK=DEFAULT"),
            .init("ALTER TABLE ddlcompat.t ALGORITHM=COPY"),
            .init("ALTER TABLE ddlcompat.t DROP e RESTRICT,DROP d CASCADE", restartBefore: true),
            .init(
                "UPDATE ddlcompat.t SET a=12,renamed=22,c=8 WHERE id=1",
                [.init("SELECT id,a,renamed,c FROM ddlcompat.t ORDER BY id", "1\t12\t22\t8\n2\t11\t21\t3")]),
            .init("CREATE TABLE ddlcompat.s(id SERIAL,v INT UNIQUE)"),
            .init("INSERT INTO ddlcompat.s(v) VALUES(40),(41)"),
            .init("UPDATE ddlcompat.s SET v=42 WHERE id=1", restartBefore: true),
            .init("CREATE TABLE ddlcompat.q(id BIGINT UNSIGNED SERIAL DEFAULT VALUE,v INT)"),
            .init("INSERT INTO ddlcompat.q(v) VALUES(50),(51)"),
            .init("ALTER TABLE ddlcompat.q ADD (extra INT,UNIQUE KEY(extra))"),
            .init("UPDATE ddlcompat.q SET extra=60 WHERE id=1", restartBefore: true),
            .init("DELETE FROM ddlcompat.s WHERE id=2"),
            .init("DROP TABLE ddlcompat.t,ddlcompat.s,ddlcompat.q"),
        ])
}
