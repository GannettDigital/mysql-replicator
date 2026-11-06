import Foundation

/// Retain every JSON phase; use MySQL scalar types and exact strings for final checks.
enum DMLJSONWorkflows {
    static let json = DMLExecutionWorkflow(
        title: "JSON values: documents, scalar types and primary-key changes",
        histories: [
            .init(table: "jv_after_insert", throughPhase: 1),
            .init(table: "jv_after_key_update", throughPhase: 2),
            .init(table: "jv_after_add", throughPhase: 3),
        ], phaseTransactions: [1, 1, 2, 1],
        predicateIDs: [
            "inserted-json-and-sql-null", "changed-key-and-signed-integer", "added-json-column-and-array",
            "deleted-non-null-documents",
        ],
        additionalChecks: [
            .init(
                id: "inserted-document-types",
                check: .init(
                    "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jv_after_insert ORDER BY id",
                    "1\tOBJECT\t2\n2\tNULL\t1\n3\tSQL_NULL\tSQL_NULL\n4\tSTRING\t1\n5\tDOUBLE\t1\n6\tOBJECT\t0")),
            .init(
                id: "inserted-object-values",
                check: .init(
                    "SELECT JSON_TYPE(doc->'$.n'),JSON_UNQUOTE(doc->'$.n'),JSON_TYPE(doc->'$.a'),JSON_LENGTH(doc->'$.a'),JSON_TYPE(doc->'$.a[0]'),JSON_UNQUOTE(doc->'$.a[0]'),JSON_TYPE(doc->'$.a[1]'),JSON_UNQUOTE(doc->'$.a[1]'),JSON_TYPE(doc->'$.a[2]') FROM poc.jv_after_insert WHERE id=1",
                    "UNSIGNED INTEGER\t18446744073709551615\tARRAY\t3\tINTEGER\t1\tBOOLEAN\ttrue\tNULL")),
            .init(
                id: "exact-unicode-string",
                check: .init("SELECT HEX(JSON_UNQUOTE(doc)) FROM poc.jv_after_insert WHERE id=4", "F09F988065CC81")),
            .init(
                id: "double-root-type-and-value",
                check: .init(
                    "SELECT JSON_TYPE(doc),CAST(JSON_UNQUOTE(doc) AS DECIMAL(3,2)) FROM poc.jv_after_insert WHERE id=5",
                    "DOUBLE\t1.00")),
            .init(
                id: "key-update-document-types",
                check: .init(
                    "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jv_after_key_update ORDER BY id",
                    "2\tNULL\t1\n3\tSQL_NULL\tSQL_NULL\n4\tSTRING\t1\n5\tDOUBLE\t1\n6\tOBJECT\t0\n11\tOBJECT\t3")),
            .init(
                id: "key-update-object-values",
                check: .init(
                    "SELECT JSON_TYPE(doc->'$.n'),JSON_UNQUOTE(doc->'$.n'),JSON_LENGTH(doc->'$.a'),JSON_TYPE(doc->'$.s'),JSON_LENGTH(doc->'$.s'),HEX(JSON_UNQUOTE(doc->'$.s[0]')),HEX(JSON_UNQUOTE(doc->'$.s[1]')) FROM poc.jv_after_key_update WHERE id=11",
                    "INTEGER\t-9223372036854775808\t3\tARRAY\t2\t78\t79")),
            .init(
                id: "added-column-object-values",
                check: .init(
                    "SELECT JSON_TYPE(doc->'$.n'),JSON_UNQUOTE(doc->'$.n'),JSON_LENGTH(doc->'$.a'),JSON_TYPE(doc->'$.s'),JSON_LENGTH(doc->'$.s'),HEX(JSON_UNQUOTE(doc->'$.s[0]')),HEX(JSON_UNQUOTE(doc->'$.s[1]')) FROM poc.jv_after_add WHERE id=11",
                    "INTEGER\t-9223372036854775808\t3\tARRAY\t2\t78\t79")),
            .init(
                id: "added-column-document-types",
                check: .init(
                    "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL'),IFNULL(JSON_TYPE(extra),'SQL_NULL') FROM poc.jv_after_add ORDER BY id",
                    "2\tNULL\t1\tSQL_NULL\n3\tSQL_NULL\tSQL_NULL\tSQL_NULL\n4\tSTRING\t1\tSQL_NULL\n5\tARRAY\t2\tBOOLEAN\n6\tOBJECT\t0\tSQL_NULL\n11\tOBJECT\t3\tSQL_NULL"
                )),
            .init(
                id: "exact-large-integer-array",
                check: .init(
                    "SELECT JSON_TYPE(doc->'$[0]'),JSON_UNQUOTE(doc->'$[0]'),JSON_TYPE(doc->'$[1]'),CAST(JSON_UNQUOTE(doc->'$[1]') AS DECIMAL(3,2)),JSON_UNQUOTE(extra) FROM poc.jv_after_add WHERE id=5",
                    "INTEGER\t9007199254740993\tDOUBLE\t1.25\ttrue")),
            .init(
                id: "final-sql-null-row",
                check: .init(
                    "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL'),IFNULL(JSON_TYPE(extra),'SQL_NULL') FROM poc.matrix_json ORDER BY id",
                    "3\tSQL_NULL\tSQL_NULL\tSQL_NULL")),
        ], expectedDDL: 6, expectedRows: 34)

    static let typedjson = DMLExecutionWorkflow(
        title: "JSON scalar types: exact DECIMAL, temporal, binary and BIT values",
        histories: [
            .init(table: "jt_after_insert", throughPhase: 1),
            .init(table: "jt_after_object", throughPhase: 2),
            .init(table: "jt_after_array", throughPhase: 3),
        ], phaseTransactions: [1, 1, 1, 1],
        predicateIDs: [
            "inserted-sql-null-document-rows", "stored-native-json-scalar-types", "replaced-object-with-typed-array",
            "deleted-typed-json-rows",
        ],
        additionalChecks: [
            .init(
                id: "jt_after_insert-ordinary-fields",
                check: .init(
                    "SET time_zone='+00:00'; SELECT id,DATE_FORMAT(ts,'%Y-%m-%d %H:%i:%s.%f'),HEX(b),HEX(c),HEX(d),HEX(e),HEX(f),HEX(g),HEX(bits) FROM poc.jt_after_insert ORDER BY id",
                    "1\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF\n2\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF"
                )),
            .init(
                id: "jt_after_object-ordinary-fields",
                check: .init(
                    "SET time_zone='+00:00'; SELECT id,DATE_FORMAT(ts,'%Y-%m-%d %H:%i:%s.%f'),HEX(b),HEX(c),HEX(d),HEX(e),HEX(f),HEX(g),HEX(bits) FROM poc.jt_after_object ORDER BY id",
                    "1\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF\n2\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF"
                )),
            .init(
                id: "jt_after_array-ordinary-fields",
                check: .init(
                    "SET time_zone='+00:00'; SELECT id,DATE_FORMAT(ts,'%Y-%m-%d %H:%i:%s.%f'),HEX(b),HEX(c),HEX(d),HEX(e),HEX(f),HEX(g),HEX(bits) FROM poc.jt_after_array ORDER BY id",
                    "1\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF\n2\t2024-02-29 12:34:56.123456\t00FF\t0027\tFF00\t0102\t00FF\t00FF0000\t1FF"
                )),
            .init(
                id: "inserted-sql-null-documents",
                check: .init(
                    "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jt_after_insert ORDER BY id",
                    "1\tSQL_NULL\tSQL_NULL\n2\tSQL_NULL\tSQL_NULL")),
            .init(
                id: "object-types-and-shape",
                check: .init(
                    "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jt_after_object ORDER BY id",
                    "1\tOBJECT\t12\n2\tOBJECT\t12")),
            .init(
                id: "array-and-unchanged-object",
                check: .init(
                    "SELECT id,IFNULL(JSON_TYPE(doc),'SQL_NULL'),IFNULL(JSON_LENGTH(doc),'SQL_NULL') FROM poc.jt_after_array ORDER BY id",
                    "1\tARRAY\t4\n2\tOBJECT\t12")),
            .init(
                id: "object-scalar-values",
                check: .init(
                    "SET time_zone='+00:00'; SELECT id,JSON_TYPE(doc->'$.decimal'),JSON_UNQUOTE(doc->'$.decimal'),JSON_TYPE(doc->'$.date'),JSON_UNQUOTE(doc->'$.date'),JSON_TYPE(doc->'$.time'),JSON_UNQUOTE(doc->'$.time'),JSON_TYPE(doc->'$.datetime'),JSON_UNQUOTE(doc->'$.datetime'),JSON_TYPE(doc->'$.timestamp'),JSON_UNQUOTE(doc->'$.timestamp') FROM poc.jt_after_object ORDER BY id",
                    "1\tDECIMAL\t-12345678901234567890123456789012345.123456789012345678901234567890\tDATE\t2024-02-29\tTIME\t-630:59:58.123456\tDATETIME\t2024-02-29 12:34:56.123456\tTIMESTAMP\t2024-02-29 12:34:56.123456\n2\tDECIMAL\t-12345678901234567890123456789012345.123456789012345678901234567890\tDATE\t2024-02-29\tTIME\t-630:59:58.123456\tDATETIME\t2024-02-29 12:34:56.123456\tTIMESTAMP\t2024-02-29 12:34:56.123456"
                )),
            .init(
                id: "object-scalar-values-binary-payloads",
                check: .init(
                    "SELECT id,JSON_TYPE(doc->'$.tiny'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.tiny'),':',-1),JSON_TYPE(doc->'$.blob'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.blob'),':',-1),JSON_TYPE(doc->'$.medium'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.medium'),':',-1),JSON_TYPE(doc->'$.long'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.long'),':',-1),JSON_TYPE(doc->'$.varbinary'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.varbinary'),':',-1),JSON_TYPE(doc->'$.binary'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.binary'),':',-1),JSON_TYPE(doc->'$.bits'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.bits'),':',-1) FROM poc.jt_after_object ORDER BY id",
                    "1\tBLOB\tAP8=\tBLOB\tACc=\tBLOB\t/wA=\tBLOB\tAQI=\tBLOB\tAP8=\tBLOB\tAP8AAA==\tBIT\tAf8=\n2\tBLOB\tAP8=\tBLOB\tACc=\tBLOB\t/wA=\tBLOB\tAQI=\tBLOB\tAP8=\tBLOB\tAP8AAA==\tBIT\tAf8="
                )),
            .init(
                id: "unchanged-object-scalar-values",
                check: .init(
                    "SET time_zone='+00:00'; SELECT id,JSON_TYPE(doc->'$.decimal'),JSON_UNQUOTE(doc->'$.decimal'),JSON_TYPE(doc->'$.date'),JSON_UNQUOTE(doc->'$.date'),JSON_TYPE(doc->'$.time'),JSON_UNQUOTE(doc->'$.time'),JSON_TYPE(doc->'$.datetime'),JSON_UNQUOTE(doc->'$.datetime'),JSON_TYPE(doc->'$.timestamp'),JSON_UNQUOTE(doc->'$.timestamp') FROM poc.jt_after_array WHERE id=2 ORDER BY id",
                    "2\tDECIMAL\t-12345678901234567890123456789012345.123456789012345678901234567890\tDATE\t2024-02-29\tTIME\t-630:59:58.123456\tDATETIME\t2024-02-29 12:34:56.123456\tTIMESTAMP\t2024-02-29 12:34:56.123456"
                )),
            .init(
                id: "unchanged-object-scalar-values-binary-payloads",
                check: .init(
                    "SELECT id,JSON_TYPE(doc->'$.tiny'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.tiny'),':',-1),JSON_TYPE(doc->'$.blob'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.blob'),':',-1),JSON_TYPE(doc->'$.medium'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.medium'),':',-1),JSON_TYPE(doc->'$.long'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.long'),':',-1),JSON_TYPE(doc->'$.varbinary'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.varbinary'),':',-1),JSON_TYPE(doc->'$.binary'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.binary'),':',-1),JSON_TYPE(doc->'$.bits'),SUBSTRING_INDEX(JSON_UNQUOTE(doc->'$.bits'),':',-1) FROM poc.jt_after_array WHERE id=2 ORDER BY id",
                    "2\tBLOB\tAP8=\tBLOB\tACc=\tBLOB\t/wA=\tBLOB\tAQI=\tBLOB\tAP8=\tBLOB\tAP8AAA==\tBIT\tAf8=")),
            .init(
                id: "zero-temporal-and-exact-array-scalars",
                check: .init(
                    "SELECT JSON_TYPE(doc->'$[0]'),JSON_UNQUOTE(doc->'$[0]'),JSON_TYPE(doc->'$[1]'),JSON_UNQUOTE(doc->'$[1]'),JSON_TYPE(doc->'$[2]'),JSON_UNQUOTE(doc->'$[2]'),JSON_TYPE(doc->'$[3]'),JSON_UNQUOTE(doc->'$[3]') FROM poc.jt_after_array WHERE id=1",
                    "DATE\t0000-00-00\tDATETIME\t0000-00-00 00:00:00.000000\tUNSIGNED INTEGER\t18446744073709551615\tDECIMAL\t1.00"
                )),
            .init(id: "empty-final-table", check: .init("SELECT id FROM poc.matrix_typedjson ORDER BY id", "")),
        ], expectedDDL: 4, expectedRows: 18)

    static let jsonpartial = DMLExecutionWorkflow(
        title: "Partial JSON updates: replace and remove row events with saved source offsets",
        histories: [
            .init(table: "jp_after_insert", throughPhase: 1),
            .init(table: "jp_after_replace", throughPhase: 2),
            .init(table: "jp_after_remove", throughPhase: 3),
        ], phaseTransactions: [1, 1, 1, 1],
        predicateIDs: [
            "inserted-json-array", "replaced-decimal-and-date", "removed-first-array-element", "deleted-json-row",
        ],
        additionalChecks: [
            .init(
                id: "initial-json-values",
                check: .init(
                    "SELECT id,JSON_TYPE(doc),JSON_LENGTH(doc),JSON_TYPE(doc->'$.padding'),OCTET_LENGTH(JSON_UNQUOTE(doc->'$.padding')),HEX(JSON_UNQUOTE(doc->'$.padding'))=REPEAT('78',1000),JSON_TYPE(doc->'$.a'),JSON_LENGTH(doc->'$.a'),IFNULL(JSON_TYPE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[2]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[2]'),'SQL_NULL'),JSON_TYPE(doc->'$.d'),JSON_UNQUOTE(doc->'$.d') FROM poc.jp_after_insert ORDER BY id",
                    "1\tOBJECT\t3\tSTRING\t1000\t1\tARRAY\t3\tINTEGER\t1\tINTEGER\t2\tINTEGER\t3\tDECIMAL\t1.00")),
            .init(
                id: "replaced-json-values",
                check: .init(
                    "SELECT id,JSON_TYPE(doc),JSON_LENGTH(doc),JSON_TYPE(doc->'$.padding'),OCTET_LENGTH(JSON_UNQUOTE(doc->'$.padding')),HEX(JSON_UNQUOTE(doc->'$.padding'))=REPEAT('78',1000),JSON_TYPE(doc->'$.a'),JSON_LENGTH(doc->'$.a'),IFNULL(JSON_TYPE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[2]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[2]'),'SQL_NULL'),JSON_TYPE(doc->'$.d'),JSON_UNQUOTE(doc->'$.d') FROM poc.jp_after_replace ORDER BY id",
                    "1\tOBJECT\t3\tSTRING\t1000\t1\tARRAY\t3\tINTEGER\t1\tDECIMAL\t123.45\tINTEGER\t3\tDATE\t2024-02-29"
                )),
            .init(
                id: "removed-array-element-values",
                check: .init(
                    "SELECT id,JSON_TYPE(doc),JSON_LENGTH(doc),JSON_TYPE(doc->'$.padding'),OCTET_LENGTH(JSON_UNQUOTE(doc->'$.padding')),HEX(JSON_UNQUOTE(doc->'$.padding'))=REPEAT('78',1000),JSON_TYPE(doc->'$.a'),JSON_LENGTH(doc->'$.a'),IFNULL(JSON_TYPE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[0]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[1]'),'SQL_NULL'),IFNULL(JSON_TYPE(doc->'$.a[2]'),'SQL_NULL'),IFNULL(JSON_UNQUOTE(doc->'$.a[2]'),'SQL_NULL'),JSON_TYPE(doc->'$.d'),JSON_UNQUOTE(doc->'$.d') FROM poc.jp_after_remove ORDER BY id",
                    "1\tOBJECT\t3\tSTRING\t1000\t1\tARRAY\t2\tDECIMAL\t123.45\tINTEGER\t3\tSQL_NULL\tSQL_NULL\tDATE\t2024-02-29"
                )),
            .init(id: "empty-final-table", check: .init("SELECT id FROM poc.matrix_jsonpartial ORDER BY id", "")),
        ], expectedDDL: 4, expectedRows: 10,
        jsonDiffPhases: [.init(phase: 2, operation: .replace), .init(phase: 3, operation: .remove)])
}
