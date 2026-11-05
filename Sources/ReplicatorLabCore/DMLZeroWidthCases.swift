import Foundation

extension DMLCompatibilityCases {
    static let zeroWidth = Case(
        id: "zerowidth",
        definition:
            "id INT PRIMARY KEY,c CHAR(0) DEFAULT '',v VARCHAR(0) DEFAULT '',b BINARY(0) DEFAULT X'',w VARBINARY(0) DEFAULT X'',u VARCHAR(0) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X''",
        phases: [
            .init(
                sql:
                    "INSERT INTO poc.matrix_zerowidth VALUES(1,DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT),(2,NULL,NULL,NULL,NULL,NULL)",
                check:
                    "SELECT COUNT(*)=2 AND SUM(id=1 AND HEX(c)='' AND HEX(v)='' AND HEX(b)='' AND HEX(w)='' AND HEX(u)='')=1 AND SUM(id=2 AND c IS NULL AND v IS NULL AND b IS NULL AND w IS NULL AND u IS NULL)=1 FROM poc.matrix_zerowidth"
            ),
            .init(
                sql:
                    "UPDATE poc.matrix_zerowidth SET c=NULL,v=NULL,b=NULL,w=NULL,u=NULL WHERE id=1; UPDATE poc.matrix_zerowidth SET c='',v='',b=X'',w=X'',u='' WHERE id=2",
                check:
                    "SELECT COUNT(*)=2 AND SUM(id=1 AND c IS NULL AND v IS NULL AND b IS NULL AND w IS NULL AND u IS NULL)=1 AND SUM(id=2 AND HEX(c)='' AND HEX(v)='' AND HEX(b)='' AND HEX(w)='' AND HEX(u)='')=1 FROM poc.matrix_zerowidth"
            ),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_zerowidth MODIFY v VARCHAR(4) DEFAULT 'x',MODIFY w VARBINARY(4) DEFAULT X'ff',MODIFY u VARCHAR(4) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X'4e2d'; UPDATE poc.matrix_zerowidth SET v='hi',w=X'ff00',u='中' WHERE id=1",
                check:
                    "SELECT COUNT(*)=1 FROM poc.matrix_zerowidth WHERE id=1 AND v='hi' AND HEX(w)='FF00' AND HEX(u)='4E2D'"
            ),
            .init(
                sql:
                    "UPDATE poc.matrix_zerowidth SET v='',w=X'',u='' WHERE id=1; ALTER TABLE poc.matrix_zerowidth MODIFY v VARCHAR(0) DEFAULT '',MODIFY w VARBINARY(0) DEFAULT X'',MODIFY u VARCHAR(0) CHARACTER SET utf16 COLLATE utf16_bin DEFAULT X''; DELETE FROM poc.matrix_zerowidth WHERE id=2",
                check:
                    "SELECT COUNT(*)=1 AND SUM(id=1 AND c IS NULL AND b IS NULL AND HEX(v)='' AND HEX(w)='' AND HEX(u)='')=1 FROM poc.matrix_zerowidth"
            ),
        ],
        workflow: .init(
            title: "String data types: zero-length columns, NULL values and width changes",
            histories: [
                .init(table: "zw_after_insert", throughPhase: 1),
                .init(table: "zw_after_update", throughPhase: 2),
                .init(table: "zw_after_widen", throughPhase: 3),
            ], phaseTransactions: [1, 2, 2, 3],
            predicateIDs: [
                "inserted-empty-and-null", "swapped-empty-and-null", "widened-columns-and-updated-values",
                "shrunk-columns-and-deleted-row",
            ],
            additionalChecks: [
                .init(
                    id: "initial-rows",
                    check: .init(
                        "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(u),'NULL') FROM poc.zw_after_insert ORDER BY id",
                        "1\t\t\t\t\t\n2\tNULL\tNULL\tNULL\tNULL\tNULL")),
                .init(
                    id: "updated-rows",
                    check: .init(
                        "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(u),'NULL') FROM poc.zw_after_update ORDER BY id",
                        "1\tNULL\tNULL\tNULL\tNULL\tNULL\n2\t\t\t\t\t")),
                .init(
                    id: "widened-rows",
                    check: .init(
                        "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(u),'NULL') FROM poc.zw_after_widen ORDER BY id",
                        "1\tNULL\t6869\tNULL\tFF00\t4E2D\n2\t\t\t\t\t")),
                .init(
                    id: "final-rows",
                    check: .init(
                        "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(u),'NULL') FROM poc.matrix_zerowidth ORDER BY id",
                        "1\tNULL\t\tNULL\t\t")),
                .init(
                    id: "initial-column-types",
                    check: .init(
                        "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='zw_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                        "c\tchar(0)\tutf8mb4\tutf8mb4_bin\nv\tvarchar(0)\tutf8mb4\tutf8mb4_bin\nb\tbinary(0)\tNULL\tNULL\nw\tvarbinary(0)\tNULL\tNULL\nu\tvarchar(0)\tutf16\tutf16_bin"
                    )),
                .init(
                    id: "initial-default-bytes",
                    check: .init(
                        "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(v)),HEX(DEFAULT(b)),HEX(DEFAULT(w)),HEX(DEFAULT(u)) FROM poc.zw_after_insert WHERE id=1",
                        "\t\t\t\t")),
                .init(
                    id: "widened-column-types",
                    check: .init(
                        "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='zw_after_widen' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                        "c\tchar(0)\tutf8mb4\tutf8mb4_bin\nv\tvarchar(4)\tutf8mb4\tutf8mb4_bin\nb\tbinary(0)\tNULL\tNULL\nw\tvarbinary(4)\tNULL\tNULL\nu\tvarchar(4)\tutf16\tutf16_bin"
                    )),
                .init(
                    id: "widened-default-bytes",
                    check: .init(
                        "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(v)),HEX(DEFAULT(b)),HEX(DEFAULT(w)),HEX(DEFAULT(u)) FROM poc.zw_after_widen WHERE id=1",
                        "\t78\t\tFF\t4E2D")),
                .init(
                    id: "final-column-types",
                    check: .init(
                        "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_zerowidth' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                        "c\tchar(0)\tutf8mb4\tutf8mb4_bin\nv\tvarchar(0)\tutf8mb4\tutf8mb4_bin\nb\tbinary(0)\tNULL\tNULL\nw\tvarbinary(0)\tNULL\tNULL\nu\tvarchar(0)\tutf16\tutf16_bin"
                    )),
                .init(
                    id: "final-default-bytes",
                    check: .init(
                        "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(v)),HEX(DEFAULT(b)),HEX(DEFAULT(w)),HEX(DEFAULT(u)) FROM poc.matrix_zerowidth WHERE id=1",
                        "\t\t\t\t")),
            ], expectedDDL: 7, expectedRows: 18))
}
