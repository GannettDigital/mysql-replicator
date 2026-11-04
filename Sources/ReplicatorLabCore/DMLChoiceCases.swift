import Foundation

extension DMLCompatibilityCases {
    static let exactChoices = Case(
        id: "exactchoices",
        definition:
            "id ENUM('😀','?','a') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin PRIMARY KEY,e ENUM('é','ÿ') CHARACTER SET latin1 COLLATE latin1_bin DEFAULT 'é',s SET('😀','?','a') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'a,😀',w ENUM('†','中') CHARACTER SET utf16 COLLATE utf16_bin DEFAULT '中',n ENUM('2','a') DEFAULT 2,q ENUM('2','a') DEFAULT '2',v INT",
        phases: [
            .init(
                sql:
                    "INSERT INTO poc.matrix_exactchoices VALUES(1,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,10),(2,2,2,1,1,2,20),(3,NULL,NULL,NULL,NULL,NULL,30)",
                check:
                    "SELECT COUNT(*)=1 FROM poc.matrix_exactchoices WHERE id+0=1 AND HEX(id)='F09F9880' AND HEX(e)='E9' AND s+0=5 AND HEX(s)='F09F98802C61' AND HEX(w)='4E2D' AND n+0=2 AND q+0=1"
            ),
            .init(
                sql: "UPDATE poc.matrix_exactchoices SET e=1,s=7,w=2,n=2,q=1,v=21 WHERE id+0=2",
                check:
                    "SELECT COUNT(*)=1 FROM poc.matrix_exactchoices WHERE id+0=2 AND HEX(id)='3F' AND HEX(e)='E9' AND s+0=7 AND HEX(w)='4E2D' AND n+0=2 AND q+0=1 AND v=21"
            ),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_exactchoices ALTER n SET DEFAULT '2',ALTER q SET DEFAULT 2,ADD extra SET('é','ÿ') CHARACTER SET latin1 COLLATE latin1_bin DEFAULT 'ÿ,é'; UPDATE poc.matrix_exactchoices SET n=DEFAULT,q=DEFAULT,extra=DEFAULT WHERE id+0=1",
                check:
                    "SELECT COUNT(*)=1 FROM poc.matrix_exactchoices WHERE id+0=1 AND n+0=1 AND q+0=2 AND extra+0=3 AND HEX(extra)='E92CFF'"
            ),
            .init(
                sql:
                    "DELETE FROM poc.matrix_exactchoices WHERE id+0=3; UPDATE poc.matrix_exactchoices SET id=3 WHERE id+0=1",
                check:
                    "SELECT COUNT(*)=2 AND SUM(id+0=1)=0 AND SUM(id+0=3 AND HEX(id)='61' AND v=10)=1 FROM poc.matrix_exactchoices"
            ),
        ], orderBy: "id+0", rowMetadata: "FULL",
        workflow: .init(
            title: "ENUM and SET: encoded labels, numeric and quoted defaults",
            histories: [
                .init(table: "ex_after_insert", throughPhase: 1),
                .init(table: "ex_after_update", throughPhase: 2),
                .init(table: "ex_after_default", throughPhase: 3),
            ], phaseTransactions: [1, 1, 2, 2],
            predicateIDs: [
                "inserted-encoded-defaults", "updated-encoded-row", "changed-defaults-and-added-set",
                "deleted-and-reused-primary-key",
            ],
            additionalChecks: [
                .init(
                    id: "initial-rows",
                    check: .init(
                        "SELECT id+0,HEX(id),IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(n+0,'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(q+0,'NULL'),IFNULL(HEX(q),'NULL'),v FROM poc.ex_after_insert ORDER BY id+0",
                        "1\tF09F9880\t1\tE9\t5\tF09F98802C61\t2\t4E2D\t2\t61\t1\t32\t10\n2\t3F\t2\tFF\t2\t3F\t1\t2020\t1\t32\t2\t61\t20\n3\t61\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t30"
                    )),
                .init(
                    id: "updated-rows",
                    check: .init(
                        "SELECT id+0,HEX(id),IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(n+0,'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(q+0,'NULL'),IFNULL(HEX(q),'NULL'),v FROM poc.ex_after_update ORDER BY id+0",
                        "1\tF09F9880\t1\tE9\t5\tF09F98802C61\t2\t4E2D\t2\t61\t1\t32\t10\n2\t3F\t1\tE9\t7\tF09F98802C3F2C61\t2\t4E2D\t2\t61\t1\t32\t21\n3\t61\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t30"
                    )),
                .init(
                    id: "changed-default-rows",
                    check: .init(
                        "SELECT id+0,HEX(id),IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(n+0,'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(q+0,'NULL'),IFNULL(HEX(q),'NULL'),v,IFNULL(CAST(extra AS UNSIGNED),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.ex_after_default ORDER BY id+0",
                        "1\tF09F9880\t1\tE9\t5\tF09F98802C61\t2\t4E2D\t1\t32\t2\t61\t10\t3\tE92CFF\n2\t3F\t1\tE9\t7\tF09F98802C3F2C61\t2\t4E2D\t2\t61\t1\t32\t21\t3\tE92CFF\n3\t61\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\t30\t3\tE92CFF"
                    )),
                .init(
                    id: "final-rows",
                    check: .init(
                        "SELECT id+0,HEX(id),IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(n+0,'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(q+0,'NULL'),IFNULL(HEX(q),'NULL'),v,IFNULL(CAST(extra AS UNSIGNED),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.matrix_exactchoices ORDER BY id+0",
                        "2\t3F\t1\tE9\t7\tF09F98802C3F2C61\t2\t4E2D\t2\t61\t1\t32\t21\t3\tE92CFF\n3\t61\t1\tE9\t5\tF09F98802C61\t2\t4E2D\t1\t32\t2\t61\t10\t3\tE92CFF"
                    )),
                .init(
                    id: "original-default-bytes",
                    check: .init(
                        "SELECT HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(e)),HEX(DEFAULT(s)),HEX(DEFAULT(w)) FROM poc.ex_after_insert WHERE id+0=1",
                        "61\t32\tE9\tF09F98802C61\t4E2D")),
                .init(
                    id: "changed-default-bytes",
                    check: .init(
                        "SELECT HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(e)),HEX(DEFAULT(s)),HEX(DEFAULT(w)),HEX(DEFAULT(extra)) FROM poc.ex_after_default WHERE id+0=1",
                        "32\t61\tE9\tF09F98802C61\t4E2D\tE92CFF")),
            ], expectedDDL: 6, expectedRows: 19, order: .idOrdinal))
    static let choiceBoundaries: Case = {
        let members = (1...64).map { "'s\($0)'" }.joined(separator: ",")
        return Case(
            id: "choiceboundaries",
            definition:
                "id INT PRIMARY KEY,e ENUM('','a  ','it''s','a\\\\b') CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'a',w ENUM('†','中') CHARACTER SET utf16le COLLATE utf16le_bin DEFAULT '†',s SET('†','中') CHARACTER SET utf32 COLLATE utf32_bin DEFAULT '中,†',g ENUM('😀','?') CHARACTER SET gb18030 COLLATE gb18030_bin DEFAULT '😀',bits SET(\(members)) DEFAULT 's64'",
            phases: [
                .init(
                    sql:
                        "INSERT INTO poc.matrix_choiceboundaries VALUES(1,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT),(2,1,2,0,2,18446744073709551615),(3,NULL,NULL,NULL,NULL,NULL)",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_choiceboundaries WHERE id=1 AND e+0=2 AND HEX(e)='61' AND HEX(w)='2020' AND s+0=3 AND HEX(s)='000020200000002C00004E2D' AND HEX(g)='9439FC36' AND CAST(bits AS UNSIGNED)=9223372036854775808"
                ),
                .init(
                    sql: "UPDATE poc.matrix_choiceboundaries SET e=4,w=2,s=2,bits=1 WHERE id=2",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_choiceboundaries WHERE id=2 AND HEX(e)='615C62' AND HEX(w)='2D4E' AND HEX(s)='00004E2D' AND bits+0=1"
                ),
                .init(
                    sql: "DELETE FROM poc.matrix_choiceboundaries WHERE id=1",
                    check:
                        "SELECT COUNT(*)=2 AND SUM(id=2 AND e+0=4)=1 AND SUM(id=3 AND e IS NULL)=1 FROM poc.matrix_choiceboundaries"
                ),
            ], rowMetadata: "FULL",
            workflow: .init(
                title: "ENUM and SET: trimmed labels, escapes and multibyte boundaries",
                histories: [
                    .init(table: "cb_after_insert", throughPhase: 1),
                    .init(table: "cb_after_update", throughPhase: 2),
                ], phaseTransactions: [1, 1, 1],
                predicateIDs: [
                    "inserted-defaults-and-high-bit", "updated-escaped-and-multibyte-values", "deleted-default-row",
                ],
                additionalChecks: [
                    .init(
                        id: "initial-rows",
                        check: .init(
                            "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(g+0,'NULL'),IFNULL(HEX(g),'NULL'),IFNULL(CAST(bits AS UNSIGNED),'NULL'),IFNULL(HEX(bits),'NULL') FROM poc.cb_after_insert ORDER BY id",
                            "1\t2\t61\t1\t2020\t3\t000020200000002C00004E2D\t1\t9439FC36\t9223372036854775808\t733634\n2\t1\t\t2\t2D4E\t0\t\t2\t3F\t18446744073709551615\t73312C73322C73332C73342C73352C73362C73372C73382C73392C7331302C7331312C7331322C7331332C7331342C7331352C7331362C7331372C7331382C7331392C7332302C7332312C7332322C7332332C7332342C7332352C7332362C7332372C7332382C7332392C7333302C7333312C7333322C7333332C7333342C7333352C7333362C7333372C7333382C7333392C7334302C7334312C7334322C7334332C7334342C7334352C7334362C7334372C7334382C7334392C7335302C7335312C7335322C7335332C7335342C7335352C7335362C7335372C7335382C7335392C7336302C7336312C7336322C7336332C733634\n3\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
                        )),
                    .init(
                        id: "updated-rows",
                        check: .init(
                            "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(g+0,'NULL'),IFNULL(HEX(g),'NULL'),IFNULL(CAST(bits AS UNSIGNED),'NULL'),IFNULL(HEX(bits),'NULL') FROM poc.cb_after_update ORDER BY id",
                            "1\t2\t61\t1\t2020\t3\t000020200000002C00004E2D\t1\t9439FC36\t9223372036854775808\t733634\n2\t4\t615C62\t2\t2D4E\t2\t00004E2D\t2\t3F\t1\t7331\n3\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
                        )),
                    .init(
                        id: "final-rows",
                        check: .init(
                            "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(w+0,'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(g+0,'NULL'),IFNULL(HEX(g),'NULL'),IFNULL(CAST(bits AS UNSIGNED),'NULL'),IFNULL(HEX(bits),'NULL') FROM poc.matrix_choiceboundaries ORDER BY id",
                            "2\t4\t615C62\t2\t2D4E\t2\t00004E2D\t2\t3F\t1\t7331\n3\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
                        )),
                    .init(
                        id: "default-bytes",
                        check: .init(
                            "SELECT HEX(DEFAULT(e)),HEX(DEFAULT(w)),HEX(DEFAULT(s)),HEX(DEFAULT(g)),HEX(DEFAULT(bits)) FROM poc.cb_after_insert WHERE id=1",
                            "61\t2020\t000020200000002C00004E2D\t9439FC36\t733634"
                        )),
                ], expectedDDL: 3, expectedRows: 12))
    }()
    static let binaryChoices = Case(
        id: "binarychoices",
        definition:
            "id INT PRIMARY KEY,e ENUM(0xFF,0x61,X'') CHARACTER SET binary DEFAULT X'FF',s SET(X'41',B'1100001') CHARACTER SET binary DEFAULT X'412C61',l ENUM(X'e9',0xff) CHARACTER SET latin1 COLLATE latin1_bin DEFAULT X'e9'",
        phases: [
            .init(
                sql:
                    "INSERT INTO poc.matrix_binarychoices VALUES(1,DEFAULT,DEFAULT,DEFAULT),(2,2,1,2),(3,3,2,1),(4,NULL,NULL,NULL)",
                check:
                    "SELECT COUNT(*)=4 AND SUM(id=1 AND HEX(e)='FF' AND s+0=3 AND HEX(s)='412C61' AND HEX(l)='E9')=1 AND SUM(id=2 AND HEX(e)='61' AND s+0=1 AND HEX(l)='FF')=1 AND SUM(id=3 AND e+0=3 AND HEX(e)='' AND s+0=2)=1 FROM poc.matrix_binarychoices"
            ),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_binarychoices ALTER e SET DEFAULT X'61',ALTER s SET DEFAULT X'41'; UPDATE poc.matrix_binarychoices SET e=DEFAULT,s=DEFAULT,l=1 WHERE id=2",
                check:
                    "SELECT COUNT(*)=1 FROM poc.matrix_binarychoices WHERE id=2 AND e+0=2 AND HEX(e)='61' AND s+0=1 AND HEX(s)='41' AND HEX(l)='E9'"
            ),
            .init(
                sql:
                    "UPDATE poc.matrix_binarychoices SET e=1,s=3,l=2 WHERE id=3; DELETE FROM poc.matrix_binarychoices WHERE id=1",
                check:
                    "SELECT COUNT(*)=3 AND SUM(id=3 AND HEX(e)='FF' AND s+0=3 AND HEX(l)='FF')=1 AND SUM(id=4 AND e IS NULL)=1 FROM poc.matrix_binarychoices"
            ),
        ], rowMetadata: "FULL",
        workflow: .init(
            title: "ENUM and SET: binary labels and hex/bit defaults",
            histories: [
                .init(table: "bc_after_insert", throughPhase: 1),
                .init(table: "bc_after_default", throughPhase: 2),
            ], phaseTransactions: [1, 2, 2],
            predicateIDs: ["inserted-binary-members", "changed-defaults-and-row", "updated-binary-row-and-delete"],
            additionalChecks: [
                .init(
                    id: "initial-rows",
                    check: .init(
                        "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(l+0,'NULL'),IFNULL(HEX(l),'NULL') FROM poc.bc_after_insert ORDER BY id",
                        "1\t1\tFF\t3\t412C61\t1\tE9\n2\t2\t61\t1\t41\t2\tFF\n3\t3\t\t2\t61\t1\tE9\n4\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
                    )),
                .init(
                    id: "changed-default-rows",
                    check: .init(
                        "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(l+0,'NULL'),IFNULL(HEX(l),'NULL') FROM poc.bc_after_default ORDER BY id",
                        "1\t1\tFF\t3\t412C61\t1\tE9\n2\t2\t61\t1\t41\t1\tE9\n3\t3\t\t2\t61\t1\tE9\n4\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
                    )),
                .init(
                    id: "final-rows",
                    check: .init(
                        "SELECT id,IFNULL(e+0,'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(CAST(s AS UNSIGNED),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(l+0,'NULL'),IFNULL(HEX(l),'NULL') FROM poc.matrix_binarychoices ORDER BY id",
                        "2\t2\t61\t1\t41\t1\tE9\n3\t1\tFF\t3\t412C61\t2\tFF\n4\tNULL\tNULL\tNULL\tNULL\tNULL\tNULL"
                    )),
                .init(
                    id: "original-default-bytes",
                    check: .init(
                        "SELECT HEX(DEFAULT(e)),HEX(DEFAULT(s)),HEX(DEFAULT(l)) FROM poc.bc_after_insert WHERE id=1",
                        "FF\t412C61\tE9")),
                .init(
                    id: "changed-default-bytes",
                    check: .init(
                        "SELECT HEX(DEFAULT(e)),HEX(DEFAULT(s)),HEX(DEFAULT(l)) FROM poc.bc_after_default WHERE id=1",
                        "61\t41\tE9")),
            ], expectedDDL: 5, expectedRows: 16))

    static let legacyBinarySet = Case(
        id: "legacybinaryset",
        definition: "id INT PRIMARY KEY,s SET(X'ff',X'61') CHARACTER SET binary DEFAULT X'ff2c61'",
        phases: [
            .init(
                sql: "INSERT INTO poc.matrix_legacybinaryset VALUES(1,DEFAULT),(2,1),(3,2),(4,NULL)",
                check:
                    "SELECT COUNT(*)=4 AND SUM(id=1 AND s+0=3 AND HEX(s)='FF2C61')=1 AND SUM(id=2 AND HEX(s)='FF')=1 AND SUM(id=3 AND HEX(s)='61')=1 AND SUM(id=4 AND s IS NULL)=1 FROM poc.matrix_legacybinaryset"
            ),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_legacybinaryset ALTER s SET DEFAULT X'ff'; UPDATE poc.matrix_legacybinaryset SET s=DEFAULT WHERE id=3; DELETE FROM poc.matrix_legacybinaryset WHERE id=1",
                check: "SELECT COUNT(*)=3 AND SUM(id=3 AND s+0=1 AND HEX(s)='FF')=1 FROM poc.matrix_legacybinaryset"),
        ],
        profileExclusions: [
            .forward:
                "MySQL 8.4.8 rejects this binary SET definition with native dictionary error 3507; the source cannot create it.",
            .reverse:
                "MySQL 8.4.8 rejects this binary SET definition with native dictionary error 3507; this is a target-version limit.",
        ])

}
