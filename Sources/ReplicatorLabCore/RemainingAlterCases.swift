import Foundation

extension DDLCompatibilityCases {
    static let columnRenames=Case("column-renames","RENAME COLUMN translation retains complete definitions, encodings and generated columns",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,a VARCHAR(30) DEFAULT 'seed' COMMENT 'keep comment',b INT GENERATED ALWAYS AS(id+1) STORED,legacy VARCHAR(20) CHARACTER SET latin1 DEFAULT 'café',KEY by_a(a(8))) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
        .init("INSERT INTO ddlcompat.t(id,a) VALUES(1,'café'),(2,'next')"),
        .init("ALTER TABLE ddlcompat.t RENAME COLUMN a TO renamed,RENAME COLUMN legacy TO legacy_name,ADD c INT DEFAULT 7",restartBefore:true),
        .init("ALTER TABLE ddlcompat.t DEFAULT CHARACTER SET latin1,RENAME COLUMN renamed TO again",[.init("SELECT HEX(legacy_name) FROM ddlcompat.t WHERE id=1","636166E9")]),
        .init("ALTER TABLE ddlcompat.t RENAME COLUMN b TO computed",restartBefore:true),
        .init("UPDATE ddlcompat.t SET again='終わり' WHERE id=1",[.init("SELECT id,HEX(again),computed,c FROM ddlcompat.t ORDER BY id","1\tE7B582E3828FE3828A\t2\t7\n2\t6E657874\t3\t7")]),
        .init("ALTER TABLE ddlcompat.t ALGORITHM=COPY,RENAME COLUMN again TO a,ORDER BY id DESC"),
        .init("INSERT INTO ddlcompat.t(id) VALUES(3)",[.init("SELECT a FROM ddlcompat.t WHERE id=3","seed")],restartBefore:true),
        .init("ALTER TABLE ddlcompat.t RENAME COLUMN a TO legacy_name,RENAME COLUMN legacy_name TO a",[.init("SELECT legacy_name,HEX(a) FROM ddlcompat.t WHERE id=3","seed\t636166E9")],restartBefore:true),
        .init("UPDATE ddlcompat.t SET legacy_name='changed' WHERE id=3",[.init("SELECT legacy_name FROM ddlcompat.t WHERE id=3","changed")]),
        .init("DROP TABLE ddlcompat.t")
    ],profileExclusions:[.reverse:"MySQL 5.7 source has no RENAME COLUMN syntax.",.mysql57MyISAM:"MySQL 5.7 source has no RENAME COLUMN syntax.",.mysql57InnoDB:"MySQL 5.7 source has no RENAME COLUMN syntax."])
    static let remainingAlterOptions=Case("alter-options","ORDER BY, validation clauses and native physical options",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) STATS_SAMPLE_PAGES=DEFAULT PASSWORD='ignored'",sqlTransactional:"CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT) COMPRESSION='none' ENCRYPTION='N' STATS_SAMPLE_PAGES=DEFAULT PASSWORD='ignored'"),
        .init("INSERT INTO ddlcompat.t VALUES(2,20),(1,10)"),
        .init("ALTER TABLE ddlcompat.t COMMENT='ordered',ORDER BY n DESC,id ASC",restartBefore:true),
        .init("ALTER TABLE ddlcompat.t ADD g INT GENERATED ALWAYS AS(n+1) VIRTUAL,WITH VALIDATION"),
        .init("ALTER TABLE ddlcompat.t MODIFY g INT GENERATED ALWAYS AS(n+2) VIRTUAL,WITHOUT VALIDATION",restartBefore:true),
        .init("UPDATE ddlcompat.t SET n=30 WHERE id=1",[.init("SELECT id,n,g FROM ddlcompat.t ORDER BY id","1\t30\t32\n2\t20\t22")]),
        .init("DROP TABLE ddlcompat.t")
    ])
}
