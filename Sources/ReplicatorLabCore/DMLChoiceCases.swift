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
        ], orderBy: "id+0", rowMetadata: "FULL")
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
            ], rowMetadata: "FULL")
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
        ], rowMetadata: "FULL")

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
