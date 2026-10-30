import Foundation

extension DDLCompatibilityCases {
    static let columnSwaps = Case(
        "column-swaps", "ALTER TABLE: swap column names and preserve key references",
        [
            // Keep the original sequence first so replay stops and restarts do not move.
            .init("CREATE TABLE ddlcompat.t(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.t VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.t CHANGE a b INT,CHANGE b a INT", phaseEnd: "before-restart-1"),
            .init("UPDATE ddlcompat.t SET a=11,c=101 WHERE b=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t CHANGE b a INT AFTER c,CHANGE a b INT FIRST", phaseEnd: "before-restart-2"),
            .init("ALTER TABLE ddlcompat.t CHANGE c d INT,CHANGE b c INT,CHANGE a b INT", restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t ADD n INT DEFAULT 7 AFTER b,CHANGE b c INT,CHANGE c b INT",
                phaseEnd: "before-restart-3"),
            .init("UPDATE ddlcompat.t SET b=12,d=102 WHERE c=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t DROP INDEX kb,DROP b,CHANGE n b INT"),
            .init("DELETE FROM ddlcompat.t WHERE c=2"),
            .init("CREATE TABLE ddlcompat.g(id INT PRIMARY KEY,a INT,b INT,g INT GENERATED ALWAYS AS(a+1) STORED)"),
            .init("INSERT INTO ddlcompat.g(id,a,b) VALUES(1,10,20)", phaseEnd: "before-restart-4"),
            .init(
                "ALTER TABLE ddlcompat.g CHANGE a b INT,CHANGE b a INT,MODIFY g INT GENERATED ALWAYS AS(b+1) STORED",
                restartBefore: true),
            .init("UPDATE ddlcompat.g SET b=12 WHERE id=1"),
            .init("DROP TABLE ddlcompat.g,ddlcompat.t"),
            // Repeat each required prefix on its own table for final comparisons.
            .init("CREATE TABLE ddlcompat.cs_seed(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_seed VALUES(1,10,100),(2,20,200)"),
            .init("CREATE TABLE ddlcompat.cs_swapped(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_swapped VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.cs_swapped CHANGE a b INT,CHANGE b a INT"),
            .init("CREATE TABLE ddlcompat.cs_written(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_written VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.cs_written CHANGE a b INT,CHANGE b a INT"),
            .init("UPDATE ddlcompat.cs_written SET a=11,c=101 WHERE b=1"),
            .init("CREATE TABLE ddlcompat.cs_positioned(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_positioned VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.cs_positioned CHANGE a b INT,CHANGE b a INT"),
            .init("UPDATE ddlcompat.cs_positioned SET a=11,c=101 WHERE b=1"),
            .init("ALTER TABLE ddlcompat.cs_positioned CHANGE b a INT AFTER c,CHANGE a b INT FIRST"),
            .init("CREATE TABLE ddlcompat.cs_chain(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_chain VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.cs_chain CHANGE a b INT,CHANGE b a INT"),
            .init("UPDATE ddlcompat.cs_chain SET a=11,c=101 WHERE b=1"),
            .init("ALTER TABLE ddlcompat.cs_chain CHANGE b a INT AFTER c,CHANGE a b INT FIRST"),
            .init("ALTER TABLE ddlcompat.cs_chain CHANGE c d INT,CHANGE b c INT,CHANGE a b INT"),
            .init("CREATE TABLE ddlcompat.cs_added(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_added VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.cs_added CHANGE a b INT,CHANGE b a INT"),
            .init("UPDATE ddlcompat.cs_added SET a=11,c=101 WHERE b=1"),
            .init("ALTER TABLE ddlcompat.cs_added CHANGE b a INT AFTER c,CHANGE a b INT FIRST"),
            .init("ALTER TABLE ddlcompat.cs_added CHANGE c d INT,CHANGE b c INT,CHANGE a b INT"),
            .init("ALTER TABLE ddlcompat.cs_added ADD n INT DEFAULT 7 AFTER b,CHANGE b c INT,CHANGE c b INT"),
            .init("CREATE TABLE ddlcompat.cs_added_write(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_added_write VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.cs_added_write CHANGE a b INT,CHANGE b a INT"),
            .init("UPDATE ddlcompat.cs_added_write SET a=11,c=101 WHERE b=1"),
            .init("ALTER TABLE ddlcompat.cs_added_write CHANGE b a INT AFTER c,CHANGE a b INT FIRST"),
            .init("ALTER TABLE ddlcompat.cs_added_write CHANGE c d INT,CHANGE b c INT,CHANGE a b INT"),
            .init("ALTER TABLE ddlcompat.cs_added_write ADD n INT DEFAULT 7 AFTER b,CHANGE b c INT,CHANGE c b INT"),
            .init("UPDATE ddlcompat.cs_added_write SET b=12,d=102 WHERE c=1"),
            .init("CREATE TABLE ddlcompat.cs_reused(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_reused VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.cs_reused CHANGE a b INT,CHANGE b a INT"),
            .init("UPDATE ddlcompat.cs_reused SET a=11,c=101 WHERE b=1"),
            .init("ALTER TABLE ddlcompat.cs_reused CHANGE b a INT AFTER c,CHANGE a b INT FIRST"),
            .init("ALTER TABLE ddlcompat.cs_reused CHANGE c d INT,CHANGE b c INT,CHANGE a b INT"),
            .init("ALTER TABLE ddlcompat.cs_reused ADD n INT DEFAULT 7 AFTER b,CHANGE b c INT,CHANGE c b INT"),
            .init("UPDATE ddlcompat.cs_reused SET b=12,d=102 WHERE c=1"),
            .init("ALTER TABLE ddlcompat.cs_reused DROP INDEX kb,DROP b,CHANGE n b INT"),
            .init("CREATE TABLE ddlcompat.cs_deleted(a INT,b INT,c INT,PRIMARY KEY(a,b),UNIQUE ka(a),KEY kb(b))"),
            .init("INSERT INTO ddlcompat.cs_deleted VALUES(1,10,100),(2,20,200)"),
            .init("ALTER TABLE ddlcompat.cs_deleted CHANGE a b INT,CHANGE b a INT"),
            .init("UPDATE ddlcompat.cs_deleted SET a=11,c=101 WHERE b=1"),
            .init("ALTER TABLE ddlcompat.cs_deleted CHANGE b a INT AFTER c,CHANGE a b INT FIRST"),
            .init("ALTER TABLE ddlcompat.cs_deleted CHANGE c d INT,CHANGE b c INT,CHANGE a b INT"),
            .init("ALTER TABLE ddlcompat.cs_deleted ADD n INT DEFAULT 7 AFTER b,CHANGE b c INT,CHANGE c b INT"),
            .init("UPDATE ddlcompat.cs_deleted SET b=12,d=102 WHERE c=1"),
            .init("ALTER TABLE ddlcompat.cs_deleted DROP INDEX kb,DROP b,CHANGE n b INT"),
            .init("DELETE FROM ddlcompat.cs_deleted WHERE c=2"),
            .init(
                "CREATE TABLE ddlcompat.cs_g_seed(id INT PRIMARY KEY,a INT,b INT,g INT GENERATED ALWAYS AS(a+1) STORED)"
            ),
            .init("INSERT INTO ddlcompat.cs_g_seed(id,a,b) VALUES(1,10,20)"),
            .init(
                "CREATE TABLE ddlcompat.cs_g_swapped(id INT PRIMARY KEY,a INT,b INT,g INT GENERATED ALWAYS AS(a+1) STORED)"
            ),
            .init("INSERT INTO ddlcompat.cs_g_swapped(id,a,b) VALUES(1,10,20)"),
            .init(
                "ALTER TABLE ddlcompat.cs_g_swapped CHANGE a b INT,CHANGE b a INT,MODIFY g INT GENERATED ALWAYS AS(b+1) STORED"
            ),
            .init(
                "CREATE TABLE ddlcompat.cs_g_updated(id INT PRIMARY KEY,a INT,b INT,g INT GENERATED ALWAYS AS(a+1) STORED)"
            ),
            .init("INSERT INTO ddlcompat.cs_g_updated(id,a,b) VALUES(1,10,20)"),
            .init(
                "ALTER TABLE ddlcompat.cs_g_updated CHANGE a b INT,CHANGE b a INT,MODIFY g INT GENERATED ALWAYS AS(b+1) STORED"
            ),
            .init("UPDATE ddlcompat.cs_g_updated SET b=12 WHERE id=1", phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "cs-swapped-values",
                    check: .init("SELECT * FROM ddlcompat.cs_swapped ORDER BY b", "1\t10\t100\n2\t20\t200")),
                .init(
                    id: "cs-swapped-keys",
                    check: .init(
                        "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cs_swapped' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                        "PRIMARY\tb\nPRIMARY\ta\nka\tb\nkb\ta")),
                .init(
                    id: "cs-written-values",
                    check: .init("SELECT b,a,c FROM ddlcompat.cs_written WHERE b=1", "1\t11\t101")),
                .init(
                    id: "cs-positioned-values",
                    check: .init("SELECT * FROM ddlcompat.cs_positioned ORDER BY a", "11\t101\t1\n20\t200\t2")),
                .init(
                    id: "cs-chain-values",
                    check: .init("SELECT * FROM ddlcompat.cs_chain ORDER BY b", "11\t101\t1\n20\t200\t2")),
                .init(
                    id: "cs-added-values",
                    check: .init("SELECT * FROM ddlcompat.cs_added ORDER BY c", "11\t7\t101\t1\n20\t7\t200\t2")),
                .init(
                    id: "cs-added-write-values",
                    check: .init(
                        "SELECT b,n,d,c FROM ddlcompat.cs_added_write ORDER BY c", "12\t7\t102\t1\n20\t7\t200\t2")),
                .init(
                    id: "cs-reused-values",
                    check: .init("SELECT * FROM ddlcompat.cs_reused ORDER BY c", "7\t102\t1\n7\t200\t2")),
                .init(id: "cs-deleted-values", check: .init("SELECT * FROM ddlcompat.cs_deleted", "7\t102\t1")),
                .init(
                    id: "cs-g-swapped-values",
                    check: .init("SELECT id,b,a,g FROM ddlcompat.cs_g_swapped", "1\t10\t20\t11")),
                .init(
                    id: "cs-g-updated-values",
                    check: .init("SELECT id,b,a,g FROM ddlcompat.cs_g_updated", "1\t12\t20\t13")),
                .init(
                    id: "seed-values",
                    check: .init("SELECT * FROM ddlcompat.cs_seed ORDER BY a", "1\t10\t100\n2\t20\t200")),
                .init(id: "generated-seed", check: .init("SELECT id,a,b,g FROM ddlcompat.cs_g_seed", "1\t10\t20\t11")),
                .init(
                    id: "keys-after-column-drop",
                    check: .init(
                        "SELECT INDEX_NAME,COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='cs_reused' ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX",
                        "PRIMARY\tc\nka\tc")),
                .init(
                    id: "original-tables-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','g')",
                        "0")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.cs_seed,ddlcompat.cs_swapped,ddlcompat.cs_written,ddlcompat.cs_positioned,ddlcompat.cs_chain,ddlcompat.cs_added,ddlcompat.cs_added_write,ddlcompat.cs_reused,ddlcompat.cs_deleted,ddlcompat.cs_g_seed,ddlcompat.cs_g_swapped,ddlcompat.cs_g_updated"
            ]
        ))
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
