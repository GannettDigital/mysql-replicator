import Foundation

extension DDLCompatibilityCases {
    static let columnSwaps = Case(
        "column-swaps",
        "Simultaneous CHANGE names, key identities, column positions, generated expressions, restart and replay",
        [
            .init("CREATE TABLE ddlcompat.t(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10,100),(2,20,200)"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE a b INT,CHANGE b a INT",
                [
                    .init("SELECT * FROM ddlcompat.t ORDER BY b", "1\t10\t100\n2\t20\t200"),
                    .init(
                        "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                        "PRIMARY\tb\nPRIMARY\ta\nka\tb\nkb\ta"),
                ]),
            .init(
                "UPDATE ddlcompat.t SET a=11,c=101 WHERE b=1",
                [.init("SELECT b,a,c FROM ddlcompat.t WHERE b=1", "1\t11\t101")], restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE b a INT AFTER c,CHANGE a b INT FIRST",
                [.init("SELECT * FROM ddlcompat.t ORDER BY a", "11\t101\t1\n20\t200\t2")]),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE c d INT,CHANGE b c INT,CHANGE a b INT",
                [.init("SELECT * FROM ddlcompat.t ORDER BY b", "11\t101\t1\n20\t200\t2")], restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t ADD n INT DEFAULT 7 AFTER b,CHANGE b c INT,CHANGE c b INT",
                [.init("SELECT * FROM ddlcompat.t ORDER BY c", "11\t7\t101\t1\n20\t7\t200\t2")]),
            .init(
                "UPDATE ddlcompat.t SET b=12,d=102 WHERE c=1",
                [.init("SELECT b,n,d,c FROM ddlcompat.t ORDER BY c", "12\t7\t102\t1\n20\t7\t200\t2")],
                restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t DROP INDEX kb,DROP b,CHANGE n b INT",
                [.init("SELECT * FROM ddlcompat.t ORDER BY c", "7\t102\t1\n7\t200\t2")]),
            .init("DELETE FROM ddlcompat.t WHERE c=2", [.init("SELECT * FROM ddlcompat.t", "7\t102\t1")]),
            .init("CREATE TABLE ddlcompat.g(id INT PRIMARY KEY,a INT,b INT,g INT GENERATED ALWAYS AS(a+1) STORED)"),
            .init("INSERT INTO ddlcompat.g(id,a,b) VALUES(1,10,20)"),
            .init(
                "ALTER TABLE ddlcompat.g CHANGE a b INT,CHANGE b a INT,MODIFY g INT GENERATED ALWAYS AS(b+1) STORED",
                [.init("SELECT id,b,a,g FROM ddlcompat.g", "1\t10\t20\t11")], restartBefore: true),
            .init(
                "UPDATE ddlcompat.g SET b=12 WHERE id=1", [.init("SELECT id,b,a,g FROM ddlcompat.g", "1\t12\t20\t13")]),
            .init("DROP TABLE ddlcompat.g,ddlcompat.t"),
        ])
    static let foreignKeyColumnSwaps = Case(
        "foreign-key-column-swaps",
        "Parent, child and self FK column swaps, new FK definitions, cascades, restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.p(id INT PRIMARY KEY,a INT NOT NULL,b INT NOT NULL,UNIQUE ka(a),UNIQUE kb(b))"),
            .init(
                "CREATE TABLE ddlcompat.c(id INT PRIMARY KEY,x INT,y INT,CONSTRAINT fa FOREIGN KEY(x) REFERENCES ddlcompat.p(a) ON UPDATE CASCADE,CONSTRAINT fb FOREIGN KEY(y) REFERENCES ddlcompat.p(b) ON UPDATE CASCADE)"
            ),
            .init("INSERT INTO ddlcompat.p VALUES(1,10,20)"),
            .init("INSERT INTO ddlcompat.c VALUES(1,10,20)"),
            .init(
                "ALTER TABLE ddlcompat.p CHANGE a b INT NOT NULL,CHANGE b a INT NOT NULL",
                [
                    .init(
                        "SELECT CONSTRAINT_NAME,COLUMN_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='c' AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY CONSTRAINT_NAME",
                        "fa\tx\tb\nfb\ty\ta")
                ], restartBefore: true),
            .init("UPDATE ddlcompat.p SET b=11,a=21 WHERE id=1", [.init("SELECT * FROM ddlcompat.c", "1\t11\t21")]),
            .init(
                "ALTER TABLE ddlcompat.c CHANGE x y INT AFTER id,CHANGE y x INT FIRST",
                [.init("SELECT * FROM ddlcompat.c", "21\t1\t11")], restartBefore: true),
            .init("UPDATE ddlcompat.p SET b=12,a=22 WHERE id=1", [.init("SELECT * FROM ddlcompat.c", "22\t1\t12")]),
            .init(
                "ALTER TABLE ddlcompat.c DROP FOREIGN KEY fa,DROP FOREIGN KEY fb,CHANGE y x INT,CHANGE x y INT,ADD CONSTRAINT fc FOREIGN KEY(x) REFERENCES ddlcompat.p(b) ON UPDATE CASCADE,ADD CONSTRAINT fd FOREIGN KEY(y) REFERENCES ddlcompat.p(a) ON UPDATE CASCADE",
                [
                    .init(
                        "SELECT CONSTRAINT_NAME,COLUMN_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='c' AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY CONSTRAINT_NAME",
                        "fc\tx\tb\nfd\ty\ta")
                ], restartBefore: true),
            .init(
                "UPDATE ddlcompat.p SET b=13,a=23 WHERE id=1", [.init("SELECT id,x,y FROM ddlcompat.c", "1\t13\t23")]),
            .init(
                "CREATE TABLE ddlcompat.s(id INT PRIMARY KEY,pid INT,CONSTRAINT fs FOREIGN KEY(pid) REFERENCES ddlcompat.s(id))"
            ),
            .init("INSERT INTO ddlcompat.s VALUES(1,NULL),(2,1)"),
            .init(
                "ALTER TABLE ddlcompat.s CHANGE id pid INT,CHANGE pid id INT",
                [.init("SELECT pid,id FROM ddlcompat.s ORDER BY pid", "1\tNULL\n2\t1")], restartBefore: true),
            .init(
                "INSERT INTO ddlcompat.s(pid,id) VALUES(3,2)",
                [.init("SELECT pid,id FROM ddlcompat.s ORDER BY pid", "1\tNULL\n2\t1\n3\t2")]),
            .init("DROP TABLE ddlcompat.c,ddlcompat.p,ddlcompat.s"),
        ])
}
