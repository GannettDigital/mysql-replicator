import Foundation

extension DDLCompatibilityCases {
    static let generatedDependencies = Case(
        "generated-dependencies", "ALTER TABLE: generated-column dependencies and conversions",
        [
            // Keep the original sequence first so replay stops and restarts do not move.
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.t(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.t CHANGE a b INT,MODIFY g INT AS(b+2) STORED", phaseEnd: "before-restart-1"),
            .init("UPDATE ddlcompat.t SET b=6 WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t MODIFY g INT AS(c+3) STORED,CHANGE b c INT"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL",
                phaseEnd: "before-restart-2"),
            .init("UPDATE ddlcompat.t SET c=7 WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t CHANGE c d INT,DROP h,MODIFY new_g INT AS(d+4) STORED"),
            .init("ALTER TABLE ddlcompat.t MODIFY new_g INT", phaseEnd: "before-restart-3"),
            .init("UPDATE ddlcompat.t SET new_g=12 WHERE id=1", restartBefore: true),
            .init("ALTER TABLE ddlcompat.t MODIFY d INT AS(id+3) STORED", phaseEnd: "before-restart-4"),
            .init("UPDATE ddlcompat.t SET id=2 WHERE id=1", restartBefore: true),
            .init("CREATE TABLE ddlcompat.q(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED)"),
            .init("INSERT INTO ddlcompat.q(id,a) VALUES(1,8)"),
            .init("ALTER TABLE ddlcompat.q CHANGE a b INT,DROP g"),
            .init("ALTER TABLE ddlcompat.q ADD g INT AS(b*2) STORED"),
            .init("ALTER TABLE ddlcompat.q DROP g,CHANGE b c INT"),
            .init("UPDATE ddlcompat.q SET c=9 WHERE id=1"),
            .init("CREATE TABLE ddlcompat.l(id INT PRIMARY KEY,a INT,g VARCHAR(10) AS('`a`') STORED)"),
            .init("INSERT INTO ddlcompat.l(id,a) VALUES(1,10)"),
            .init("ALTER TABLE ddlcompat.l CHANGE a b INT"),
            .init("DELETE FROM ddlcompat.l WHERE id=1"),
            .init("DROP TABLE ddlcompat.t,ddlcompat.q,ddlcompat.l"),
            // Repeat each required prefix on its own table for final comparisons.
            .init(
                "CREATE TABLE ddlcompat.gd_seed(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_seed(id,a) VALUES(1,5)"),
            .init(
                "CREATE TABLE ddlcompat.gd_replaced(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_replaced(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_replaced CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init(
                "CREATE TABLE ddlcompat.gd_replaced_write(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_replaced_write(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_replaced_write CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init("UPDATE ddlcompat.gd_replaced_write SET b=6 WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.gd_reverse_order(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_reverse_order(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_reverse_order CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init("UPDATE ddlcompat.gd_reverse_order SET b=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_reverse_order MODIFY g INT AS(c+3) STORED,CHANGE b c INT"),
            .init(
                "CREATE TABLE ddlcompat.gd_renamed(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_renamed(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_renamed CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init("UPDATE ddlcompat.gd_renamed SET b=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_renamed MODIFY g INT AS(c+3) STORED,CHANGE b c INT"),
            .init(
                "ALTER TABLE ddlcompat.gd_renamed CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL"),
            .init(
                "CREATE TABLE ddlcompat.gd_renamed_write(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_renamed_write(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_renamed_write CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init("UPDATE ddlcompat.gd_renamed_write SET b=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_renamed_write MODIFY g INT AS(c+3) STORED,CHANGE b c INT"),
            .init(
                "ALTER TABLE ddlcompat.gd_renamed_write CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL"
            ),
            .init("UPDATE ddlcompat.gd_renamed_write SET c=7 WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.gd_dropped(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_dropped(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_dropped CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init("UPDATE ddlcompat.gd_dropped SET b=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_dropped MODIFY g INT AS(c+3) STORED,CHANGE b c INT"),
            .init(
                "ALTER TABLE ddlcompat.gd_dropped CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL"),
            .init("UPDATE ddlcompat.gd_dropped SET c=7 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_dropped CHANGE c d INT,DROP h,MODIFY new_g INT AS(d+4) STORED"),
            .init(
                "CREATE TABLE ddlcompat.gd_ordinary(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_ordinary(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_ordinary CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init("UPDATE ddlcompat.gd_ordinary SET b=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_ordinary MODIFY g INT AS(c+3) STORED,CHANGE b c INT"),
            .init(
                "ALTER TABLE ddlcompat.gd_ordinary CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL"),
            .init("UPDATE ddlcompat.gd_ordinary SET c=7 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_ordinary CHANGE c d INT,DROP h,MODIFY new_g INT AS(d+4) STORED"),
            .init("ALTER TABLE ddlcompat.gd_ordinary MODIFY new_g INT"),
            .init(
                "CREATE TABLE ddlcompat.gd_generated(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_generated(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_generated CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init("UPDATE ddlcompat.gd_generated SET b=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_generated MODIFY g INT AS(c+3) STORED,CHANGE b c INT"),
            .init(
                "ALTER TABLE ddlcompat.gd_generated CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL"),
            .init("UPDATE ddlcompat.gd_generated SET c=7 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_generated CHANGE c d INT,DROP h,MODIFY new_g INT AS(d+4) STORED"),
            .init("ALTER TABLE ddlcompat.gd_generated MODIFY new_g INT"),
            .init("UPDATE ddlcompat.gd_generated SET new_g=12 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_generated MODIFY d INT AS(id+3) STORED"),
            .init(
                "CREATE TABLE ddlcompat.gd_final(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.gd_final(id,a) VALUES(1,5)"),
            .init("ALTER TABLE ddlcompat.gd_final CHANGE a b INT,MODIFY g INT AS(b+2) STORED"),
            .init("UPDATE ddlcompat.gd_final SET b=6 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_final MODIFY g INT AS(c+3) STORED,CHANGE b c INT"),
            .init("ALTER TABLE ddlcompat.gd_final CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL"),
            .init("UPDATE ddlcompat.gd_final SET c=7 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_final CHANGE c d INT,DROP h,MODIFY new_g INT AS(d+4) STORED"),
            .init("ALTER TABLE ddlcompat.gd_final MODIFY new_g INT"),
            .init("UPDATE ddlcompat.gd_final SET new_g=12 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gd_final MODIFY d INT AS(id+3) STORED"),
            .init("UPDATE ddlcompat.gd_final SET id=2 WHERE id=1"),
            .init("CREATE TABLE ddlcompat.gd_q_seed(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED)"),
            .init("INSERT INTO ddlcompat.gd_q_seed(id,a) VALUES(1,8)"),
            .init("CREATE TABLE ddlcompat.gd_q_dropped(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED)"),
            .init("INSERT INTO ddlcompat.gd_q_dropped(id,a) VALUES(1,8)"),
            .init("ALTER TABLE ddlcompat.gd_q_dropped CHANGE a b INT,DROP g"),
            .init("CREATE TABLE ddlcompat.gd_q_recreated(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED)"),
            .init("INSERT INTO ddlcompat.gd_q_recreated(id,a) VALUES(1,8)"),
            .init("ALTER TABLE ddlcompat.gd_q_recreated CHANGE a b INT,DROP g"),
            .init("ALTER TABLE ddlcompat.gd_q_recreated ADD g INT AS(b*2) STORED"),
            .init("CREATE TABLE ddlcompat.gd_q_final(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED)"),
            .init("INSERT INTO ddlcompat.gd_q_final(id,a) VALUES(1,8)"),
            .init("ALTER TABLE ddlcompat.gd_q_final CHANGE a b INT,DROP g"),
            .init("ALTER TABLE ddlcompat.gd_q_final ADD g INT AS(b*2) STORED"),
            .init("ALTER TABLE ddlcompat.gd_q_final DROP g,CHANGE b c INT"),
            .init("UPDATE ddlcompat.gd_q_final SET c=9 WHERE id=1"),
            .init("CREATE TABLE ddlcompat.gd_literal_seed(id INT PRIMARY KEY,a INT,g VARCHAR(10) AS('`a`') STORED)"),
            .init("INSERT INTO ddlcompat.gd_literal_seed(id,a) VALUES(1,10)"),
            .init("CREATE TABLE ddlcompat.gd_literal_renamed(id INT PRIMARY KEY,a INT,g VARCHAR(10) AS('`a`') STORED)"),
            .init("INSERT INTO ddlcompat.gd_literal_renamed(id,a) VALUES(1,10)"),
            .init("ALTER TABLE ddlcompat.gd_literal_renamed CHANGE a b INT"),
            .init("CREATE TABLE ddlcompat.gd_literal_empty(id INT PRIMARY KEY,a INT,g VARCHAR(10) AS('`a`') STORED)"),
            .init("INSERT INTO ddlcompat.gd_literal_empty(id,a) VALUES(1,10)"),
            .init("ALTER TABLE ddlcompat.gd_literal_empty CHANGE a b INT"),
            .init("DELETE FROM ddlcompat.gd_literal_empty WHERE id=1", phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "gd-replaced-values",
                    check: .init("SELECT b,g,h,literal_text FROM ddlcompat.gd_replaced", "5\t7\t14\t`a`")),
                .init(
                    id: "gd-replaced-write-values", check: .init("SELECT g,h FROM ddlcompat.gd_replaced_write", "8\t16")
                ),
                .init(
                    id: "gd-reverse-order-values",
                    check: .init("SELECT c,g,h FROM ddlcompat.gd_reverse_order", "6\t9\t18")),
                .init(
                    id: "gd-renamed-write-values",
                    check: .init("SELECT new_g,h FROM ddlcompat.gd_renamed_write", "10\t30")),
                .init(id: "gd-dropped-values", check: .init("SELECT d,new_g FROM ddlcompat.gd_dropped", "7\t11")),
                .init(id: "gd-ordinary-values", check: .init("SELECT new_g FROM ddlcompat.gd_ordinary", "11")),
                .init(id: "gd-generated-values", check: .init("SELECT d,new_g FROM ddlcompat.gd_generated", "4\t12")),
                .init(id: "gd-final-values", check: .init("SELECT d,new_g FROM ddlcompat.gd_final", "5\t12")),
                .init(id: "gd-q-dropped-values", check: .init("SELECT id,b FROM ddlcompat.gd_q_dropped", "1\t8")),
                .init(
                    id: "gd-literal-renamed-values",
                    check: .init("SELECT b,g FROM ddlcompat.gd_literal_renamed", "10\t`a`")),
                .init(
                    id: "seed-values", check: .init("SELECT a,g,h,literal_text FROM ddlcompat.gd_seed", "5\t6\t12\t`a`")
                ),
                .init(id: "renamed-before-update", check: .init("SELECT new_g,h FROM ddlcompat.gd_renamed", "9\t27")),
                .init(id: "independent-seed", check: .init("SELECT id,a,g FROM ddlcompat.gd_q_seed", "1\t8\t9")),
                .init(
                    id: "recreated-expression", check: .init("SELECT id,b,g FROM ddlcompat.gd_q_recreated", "1\t8\t16")),
                .init(id: "dropped-expression-update", check: .init("SELECT id,c FROM ddlcompat.gd_q_final", "1\t9")),
                .init(id: "literal-seed", check: .init("SELECT a,g FROM ddlcompat.gd_literal_seed", "10\t`a`")),
                .init(id: "literal-delete", check: .init("SELECT COUNT(*) FROM ddlcompat.gd_literal_empty", "0")),
                .init(
                    id: "initial-storage-forms",
                    check: .init(
                        "SELECT COLUMN_NAME,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gd_seed' AND COLUMN_NAME IN ('g','h','literal_text') ORDER BY ORDINAL_POSITION",
                        "g\tSTORED GENERATED\nh\tVIRTUAL GENERATED\nliteral_text\tSTORED GENERATED")),
                .init(
                    id: "ordinary-column",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gd_ordinary' AND COLUMN_NAME='new_g' AND EXTRA='' AND GENERATION_EXPRESSION=''",
                        "1")),
                .init(
                    id: "converted-storage-form",
                    check: .init(
                        "SELECT EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gd_generated' AND COLUMN_NAME='d'",
                        "STORED GENERATED")),
                .init(
                    id: "renamed-index",
                    check: .init(
                        "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gd_dropped' AND INDEX_NAME='by_g' ORDER BY SEQ_IN_INDEX",
                        "new_g")),
                .init(
                    id: "original-tables-dropped",
                    check: .init(
                        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME IN ('t','q','l')",
                        "0")),
            ], databases: ["ddlcompat"],
            cleanup: [
                "DROP TABLE ddlcompat.gd_seed,ddlcompat.gd_replaced,ddlcompat.gd_replaced_write,ddlcompat.gd_reverse_order,ddlcompat.gd_renamed,ddlcompat.gd_renamed_write,ddlcompat.gd_dropped,ddlcompat.gd_ordinary,ddlcompat.gd_generated,ddlcompat.gd_final,ddlcompat.gd_q_seed,ddlcompat.gd_q_dropped,ddlcompat.gd_q_recreated,ddlcompat.gd_q_final,ddlcompat.gd_literal_seed,ddlcompat.gd_literal_renamed,ddlcompat.gd_literal_empty"
            ]
        ))
}
