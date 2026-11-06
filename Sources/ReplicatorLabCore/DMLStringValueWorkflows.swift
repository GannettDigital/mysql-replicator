import Foundation

/// Retain byte values and defaults; compare large payloads with full SQL equality.
enum DMLStringValueWorkflows {
    static let binarydefaults = DMLExecutionWorkflow(
        title: "String data types: binary defaults, padding and width changes",
        histories: [
            .init(table: "bd_after_insert", throughPhase: 1),
            .init(table: "bd_after_defaults", throughPhase: 2),
        ], phaseTransactions: [1, 2, 4],
        predicateIDs: [
            "inserted-binary-defaults", "changed-binary-defaults-and-added-column",
            "changed-width-dropped-default-and-replaced-row",
        ],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT id,IFNULL(HEX(b),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(a),'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(HEX(z),'NULL'),IFNULL(HEX(c),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL') FROM poc.bd_after_insert ORDER BY id",
                    "1\tFF00010000\tFF0001\t6869000000\t\t\tFF000000\t3130300000000000\t316532\n2\tFF00010000\tFF0001\t6869000000\t\t\tFF000000\t3130300000000000\t316532"
                )),
            .init(
                id: "initial-stored-defaults",
                check: .init(
                    "SELECT HEX(DEFAULT(b)),HEX(DEFAULT(v)),HEX(DEFAULT(a)),HEX(DEFAULT(e)),HEX(DEFAULT(z)),HEX(DEFAULT(c)),HEX(DEFAULT(n)),HEX(DEFAULT(q)) FROM poc.bd_after_insert WHERE id=1",
                    "FF00010000\tFF0001\t6869000000\t\t\tFF000000\t3130300000000000\t316532")),
            .init(
                id: "initial-column-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='bd_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "b\tbinary(5)\tYES\t0\nv\tvarbinary(8)\tYES\t0\na\tbinary(5)\tYES\t0\ne\tvarbinary(5)\tYES\t0\nz\tbinary(0)\tYES\t0\nc\tbinary(4)\tYES\t0\nn\tbinary(8)\tYES\t0\nq\tvarbinary(8)\tYES\t0"
                )),
            .init(
                id: "changed-default-rows",
                check: .init(
                    "SELECT id,IFNULL(HEX(b),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(a),'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(HEX(z),'NULL'),IFNULL(HEX(c),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.bd_after_defaults ORDER BY id",
                    "1\t00FF020000\tFF\t6869000000\t\t\tFF000000\t3130300000000000\t316532\t800003\n2\tFF00010000\tFF0001\t6869000000\t\t\tFF000000\t3130300000000000\t316532\t800003"
                )),
            .init(
                id: "changed-stored-defaults",
                check: .init(
                    "SELECT HEX(DEFAULT(b)),HEX(DEFAULT(v)),HEX(DEFAULT(a)),HEX(DEFAULT(e)),HEX(DEFAULT(z)),HEX(DEFAULT(c)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(extra)) FROM poc.bd_after_defaults WHERE id=1",
                    "00FF020000\tFF\t6869000000\t\t\tFF000000\t3130300000000000\t316532\t800003")),
            .init(
                id: "changed-column-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='bd_after_defaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "b\tbinary(5)\tYES\t0\nv\tvarbinary(8)\tYES\t0\na\tbinary(5)\tYES\t0\ne\tvarbinary(5)\tYES\t0\nz\tbinary(0)\tYES\t0\nc\tbinary(4)\tYES\t0\nn\tbinary(8)\tYES\t0\nq\tvarbinary(8)\tYES\t0\nextra\tvarbinary(8)\tYES\t0"
                )),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT id,IFNULL(HEX(b),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(a),'NULL'),IFNULL(HEX(e),'NULL'),IFNULL(HEX(z),'NULL'),IFNULL(HEX(c),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.matrix_binarydefaults ORDER BY id",
                    "1\t00FF020000\t0000FF00\t686900000000\t\t\tFF000000\t3130300000000000\t316532\t800003\n3\t00FF020000\tFF\tFF0004000000\tNULL\t\tFF000000\t3130300000000000\t316532\t800003"
                )),
            .init(
                id: "final-stored-defaults",
                check: .init(
                    "SELECT HEX(DEFAULT(b)),HEX(DEFAULT(v)),HEX(DEFAULT(a)),HEX(DEFAULT(z)),HEX(DEFAULT(c)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(extra)) FROM poc.matrix_binarydefaults WHERE id=1",
                    "00FF020000\tFF\tFF0004000000\t\tFF000000\t3130300000000000\t316532\t800003")),
            .init(
                id: "final-column-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_binarydefaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "b\tbinary(5)\tYES\t0\nv\tvarbinary(8)\tYES\t0\na\tbinary(6)\tYES\t0\ne\tvarbinary(5)\tYES\t1\nz\tbinary(0)\tYES\t0\nc\tbinary(4)\tYES\t0\nn\tbinary(8)\tYES\t0\nq\tvarbinary(8)\tYES\t0\nextra\tvarbinary(8)\tYES\t0"
                )),
        ], expectedDDL: 6, expectedRows: 11)

    static let textdefaults = DMLExecutionWorkflow(
        title: "String data types: character defaults, encodings and padding",
        histories: [
            .init(table: "td_after_insert", throughPhase: 1),
            .init(table: "td_after_defaults", throughPhase: 2),
        ], phaseTransactions: [1, 2, 3],
        predicateIDs: [
            "inserted-character-defaults", "changed-defaults-under-pad-mode",
            "changed-encoding-width-and-dropped-default",
        ],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(d),'NULL') FROM poc.td_after_insert ORDER BY id",
                    "1\tF09F9880\tF09F98802020\tFF00\t4E2D\t313030\t316532\t3130300000000000\t65CC81\n2\tF09F9880\tF09F98802020\tFF00\t4E2D\t313030\t316532\t3130300000000000\t65CC81"
                )),
            .init(
                id: "initial-stored-defaults",
                check: .init(
                    "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(v)),HEX(DEFAULT(l)),HEX(DEFAULT(w)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(b)),HEX(DEFAULT(d)) FROM poc.td_after_insert WHERE id=1",
                    "F09F9880\tF09F98802020\tFF00\t4E2D\t313030\t316532\t3130300000000000\t65CC81")),
            .init(
                id: "initial-column-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='td_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "c\tchar(4)\tutf8mb4\tutf8mb4_bin\tYES\t0\nv\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nl\tvarchar(8)\tlatin1\tlatin1_bin\tYES\t0\nw\tchar(4)\tutf16\tutf16_bin\tYES\t0\nn\tchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nq\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nb\tbinary(8)\tNULL\tNULL\tYES\t0\nd\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0"
                )),
            .init(
                id: "changed-default-rows",
                check: .init(
                    "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(d),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.td_after_defaults ORDER BY id",
                    "1\tE4B8AD\tF09F98802020\tE900\t4E2D\t313030\t316532\t3130300000000000\t65CC81\tF09F988000\n2\tF09F9880\tF09F98802020\tFF00\t4E2D\t313030\t316532\t3130300000000000\t65CC81\tF09F988000"
                )),
            .init(
                id: "changed-stored-defaults",
                check: .init(
                    "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(v)),HEX(DEFAULT(l)),HEX(DEFAULT(w)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(b)),HEX(DEFAULT(d)),HEX(DEFAULT(extra)) FROM poc.td_after_defaults WHERE id=1",
                    "E4B8AD\tF09F98802020\tE900\t4E2D\t313030\t316532\t3130300000000000\t65CC81\tF09F988000")),
            .init(
                id: "changed-column-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='td_after_defaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "c\tchar(4)\tutf8mb4\tutf8mb4_bin\tYES\t0\nv\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nl\tvarchar(8)\tlatin1\tlatin1_bin\tYES\t0\nw\tchar(4)\tutf16\tutf16_bin\tYES\t0\nn\tchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nq\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nb\tbinary(8)\tNULL\tNULL\tYES\t0\nd\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nextra\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0"
                )),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(v),'NULL'),IFNULL(HEX(l),'NULL'),IFNULL(HEX(w),'NULL'),IFNULL(HEX(n),'NULL'),IFNULL(HEX(q),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(d),'NULL'),IFNULL(HEX(extra),'NULL') FROM poc.matrix_textdefaults ORDER BY id",
                    "1\tE4B8AD\tF09F98802020\tE900\t4E2D\t313030\t316532\t3130300000000000\t65CC81\tF09F988000\n3\tE4B8AD\tNULL\tE900\t20200020\t313030\t31303030\t3130300000000000\t65CC81\tF09F988000"
                )),
            .init(
                id: "final-stored-defaults",
                check: .init(
                    "SELECT HEX(DEFAULT(c)),HEX(DEFAULT(l)),HEX(DEFAULT(w)),HEX(DEFAULT(n)),HEX(DEFAULT(q)),HEX(DEFAULT(b)),HEX(DEFAULT(d)),HEX(DEFAULT(extra)) FROM poc.matrix_textdefaults WHERE id=1",
                    "E4B8AD\tE900\t20200020\t313030\t31303030\t3130300000000000\t65CC81\tF09F988000")),
            .init(
                id: "final-column-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_textdefaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "c\tchar(4)\tutf8mb4\tutf8mb4_bin\tYES\t0\nv\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t1\nl\tvarchar(8)\tlatin1\tlatin1_bin\tYES\t0\nw\tvarchar(8)\tutf16\tutf16_bin\tYES\t0\nn\tchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nq\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nb\tbinary(8)\tNULL\tNULL\tYES\t0\nd\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0\nextra\tvarchar(8)\tutf8mb4\tutf8mb4_bin\tYES\t0"
                )),
        ], expectedDDL: 6, expectedRows: 10)

    static let fixed = DMLExecutionWorkflow(
        title: "Fixed-length string types: CHAR, BINARY, padding and empty values",
        histories: [
            .init(table: "fv_after_insert", throughPhase: 1),
            .init(table: "fv_after_update", throughPhase: 2),
        ], phaseTransactions: [1, 1, 1],
        predicateIDs: [
            "inserted-trimmed-char-and-padded-binary", "updated-full-width-values", "deleted-text-and-null-rows",
        ],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(b),'NULL') FROM poc.fv_after_insert ORDER BY id",
                    "1\tF09F988065CC81\t00FF000000000000\n2\t\t0000000000000000\n3\tNULL\tNULL")),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(b),'NULL') FROM poc.fv_after_update ORDER BY id",
                    "1\t787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878\t0102030405060708\n2\t\t0000000000000000\n3\tNULL\tNULL"
                )),
            .init(
                id: "final-empty-row",
                check: .init(
                    "SELECT id,IFNULL(HEX(c),'NULL'),IFNULL(HEX(b),'NULL') FROM poc.matrix_fixed ORDER BY id",
                    "2\t\t0000000000000000")),
            .init(
                id: "fixed-length-declarations",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='fv_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "c\tchar(255)\tutf8mb4\tutf8mb4_bin\tYES\nb\tbinary(8)\tNULL\tNULL\tYES")),
        ], expectedDDL: 3, expectedRows: 13)

    static let lob = DMLExecutionWorkflow(
        title: "BLOB and TEXT types: complete values, prefix index and NULL",
        histories: [
            .init(table: "lb_after_insert", throughPhase: 1),
            .init(table: "lb_after_update", throughPhase: 2),
        ], phaseTransactions: [1, 1, 1],
        predicateIDs: ["inserted-all-blob-text-families", "updated-empty-null-and-short-values", "deleted-large-row"],
        additionalChecks: [
            .init(
                id: "complete-inserted-payloads",
                check: .init(
                    "SELECT id,IFNULL(HEX(a),'NULL'),OCTET_LENGTH(b),HEX(b)=REPEAT('78',1000),OCTET_LENGTH(c),HEX(c)=REPEAT('79',70000),IFNULL(HEX(d),'NULL'),IFNULL(HEX(e),'NULL'),OCTET_LENGTH(f),HEX(f)=REPEAT('FF',1000),OCTET_LENGTH(g),HEX(g)=REPEAT('00FF',35000),IFNULL(HEX(h),'NULL') FROM poc.lb_after_insert ORDER BY id",
                    "1\t0027F09F988065CC812020\t1000\t1\t70000\t1\t\t00FF275C\t1000\t1\t70000\t1\tNULL")),
            .init(
                id: "complete-updated-payloads",
                check: .init(
                    "SELECT id,IFNULL(HEX(a),'NULL'),IFNULL(HEX(b),'NULL'),IFNULL(HEX(c),'NULL'),IFNULL(HEX(d),'NULL'),IFNULL(HEX(e),'NULL'),OCTET_LENGTH(f),HEX(f)=REPEAT('FF',1000),OCTET_LENGTH(g),HEX(g)=REPEAT('00FF',35000),IFNULL(HEX(h),'NULL') FROM poc.lb_after_update ORDER BY id",
                    "1\tNULL\t\t73686F7274\t\t\t1000\t1\t70000\t1\t00FF")),
            .init(id: "empty-final-table", check: .init("SELECT id FROM poc.matrix_lob ORDER BY id", "")),
            .init(
                id: "all-blob-text-declarations",
                check: .init(
                    "SELECT COLUMN_NAME,DATA_TYPE,IFNULL(CHARACTER_SET_NAME,'NULL'),IFNULL(COLLATION_NAME,'NULL'),IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='lb_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "a\ttinytext\tutf8mb4\tutf8mb4_bin\tYES\nb\ttext\tutf8mb4\tutf8mb4_bin\tYES\nc\tmediumtext\tutf8mb4\tutf8mb4_bin\tYES\nd\tlongtext\tutf8mb4\tutf8mb4_bin\tYES\ne\ttinyblob\tNULL\tNULL\tYES\nf\tblob\tNULL\tNULL\tYES\ng\tmediumblob\tNULL\tNULL\tYES\nh\tlongblob\tNULL\tNULL\tYES"
                )),
            .init(
                id: "text-prefix-index",
                check: .init(
                    "SELECT INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,SUB_PART FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='lb_after_insert' AND INDEX_NAME='prefix_key' ORDER BY SEQ_IN_INDEX",
                    "prefix_key\t1\t1\tb\t10")),
        ], expectedDDL: 3, expectedRows: 6)
}
