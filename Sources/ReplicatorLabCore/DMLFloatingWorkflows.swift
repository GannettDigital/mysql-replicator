import Foundation

/// MySQL checks approximate values; the native oracle compares complete rows.
enum DMLFloatingWorkflows {
    static let floatbounds = DMLExecutionWorkflow(
        title: "Floating-point types: FLOAT(M,D) boundary rounding and key changes",
        histories: [
            .init(table: "fb_after_insert", throughPhase: 1),
            .init(table: "fb_after_update", throughPhase: 2),
        ], phaseTransactions: [1, 1, 1],
        predicateIDs: ["inserted-rounded-boundaries", "changed-float-key-and-values", "deleted-negative-key"],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(10,2)),CAST(v AS DECIMAL(10,2)),CAST(u AS DECIMAL(10,2)) FROM poc.fb_after_insert ORDER BY id",
                    "-1000000.00\t-1000000.00\t0.00\n1000000.00\t1000000.00\t1000000.00")),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(10,2)),CAST(v AS DECIMAL(10,2)),CAST(u AS DECIMAL(10,2)) FROM poc.fb_after_update ORDER BY id",
                    "-1000000.00\t-1000000.00\t0.00\n1.00\t-1000000.00\t1000000.00")),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(10,2)),CAST(v AS DECIMAL(10,2)),CAST(u AS DECIMAL(10,2)) FROM poc.matrix_floatbounds ORDER BY id",
                    "1.00\t-1000000.00\t1000000.00")),
        ], expectedDDL: 3, expectedRows: 9)

    static let zerofill = DMLExecutionWorkflow(
        title: "Numeric type attributes: ZEROFILL, unsigned limits and defaults",
        histories: [
            .init(table: "zf_after_insert", throughPhase: 1),
            .init(table: "zf_after_update", throughPhase: 2),
            .init(table: "zf_after_alter", throughPhase: 3),
        ], phaseTransactions: [1, 1, 2, 1],
        predicateIDs: [
            "inserted-numeric-defaults", "changed-unsigned-key-and-limits", "changed-width-default-and-added-column",
            "deleted-unsigned-keys",
        ],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,3)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,2)),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.zf_after_insert ORDER BY id",
                    "0\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\n1\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\n2\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL"
                )),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,3)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,2)),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.zf_after_update ORDER BY id",
                    "1\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\n2\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\n4294967295\t255\t999999.99\t0.125\t9.88\t4294967295\t18446744073709551615\t2155"
                )),
            .init(
                id: "altered-rows",
                check: .init(
                    "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,3)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,2)),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL'),IFNULL(CAST(g AS UNSIGNED),'NULL') FROM poc.zf_after_alter ORDER BY id",
                    "1\t9\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\t16777215\n2\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\t42\n4294967295\t255\t999999.99\t0.125\t9.88\t4294967295\t18446744073709551615\t2155\t42"
                )),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,3)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,2)),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL'),IFNULL(CAST(g AS UNSIGNED),'NULL') FROM poc.matrix_zerofill ORDER BY id",
                    "2\t7\t1.25\t1.250\t1.24\tNULL\tNULL\tNULL\t42")),
            .init(
                id: "initial-unsigned-zerofill-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,DATA_TYPE,LOCATE('unsigned',COLUMN_TYPE)>0,LOCATE('zerofill',COLUMN_TYPE)>0,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='zf_after_insert' AND COLUMN_NAME<>'y' ORDER BY ORDINAL_POSITION",
                    "id\tint\t1\t1\tNO\na\ttinyint\t1\t1\tYES\nb\tdecimal\t1\t1\tYES\nc\tfloat\t1\t1\tYES\nd\tdouble\t1\t1\tYES\ne\tint\t1\t1\tYES\nf\tbigint\t1\t1\tYES"
                )),
            .init(
                id: "initial-stored-defaults",
                check: .init(
                    "SELECT CAST(DEFAULT(a) AS UNSIGNED),CAST(DEFAULT(b) AS DECIMAL(8,2)),CAST(DEFAULT(c) AS DECIMAL(8,3)),CAST(DEFAULT(d) AS DECIMAL(10,2)) FROM poc.zf_after_insert WHERE id=1",
                    "7\t1.25\t1.250\t1.24")),
            .init(
                id: "altered-unsigned-zerofill-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,DATA_TYPE,LOCATE('unsigned',COLUMN_TYPE)>0,LOCATE('zerofill',COLUMN_TYPE)>0,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='zf_after_alter' AND COLUMN_NAME<>'y' ORDER BY ORDINAL_POSITION",
                    "id\tint\t1\t1\tNO\na\ttinyint\t1\t1\tYES\nb\tdecimal\t1\t1\tYES\nc\tfloat\t1\t1\tYES\nd\tdouble\t1\t1\tYES\ne\tint\t1\t1\tYES\nf\tbigint\t1\t1\tYES\ng\tmediumint\t1\t1\tYES"
                )),
            .init(
                id: "altered-stored-defaults",
                check: .init(
                    "SELECT CAST(DEFAULT(a) AS UNSIGNED),CAST(DEFAULT(b) AS DECIMAL(8,2)),CAST(DEFAULT(c) AS DECIMAL(8,3)),CAST(DEFAULT(d) AS DECIMAL(10,2)),CAST(DEFAULT(g) AS UNSIGNED) FROM poc.zf_after_alter WHERE id=1",
                    "9\t1.25\t1.250\t1.24\t42")),
        ], expectedDDL: 6, expectedRows: 19)

    static let fixedfloating = DMLExecutionWorkflow(
        title: "Floating-point types: fixed-scale rounding, defaults and changes",
        histories: [
            .init(table: "ff_after_insert", throughPhase: 1),
            .init(table: "ff_after_update", throughPhase: 2),
            .init(table: "ff_after_alter", throughPhase: 3),
        ], phaseTransactions: [2, 1, 2, 1],
        predicateIDs: [
            "inserted-fixed-scale-defaults", "changed-double-key-and-rounded-values", "changed-float-scale-and-default",
            "deleted-non-null-rows",
        ],
        additionalChecks: [
            .init(
                id: "initial-field-values",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(10,2)),IFNULL((CASE WHEN id=10.26 THEN a> -100000 AND a< -99999 WHEN id=2 THEN a>1.2399 AND a<1.2401 ELSE a>1.2399 AND a<1.2401 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN b=0 ELSE b=-1.234568 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN c> -1.000001e-5 AND c< -9.99999e-6 ELSE c>0.09999999 AND c<0.10000001 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN d=-1e199 ELSE d=1e199 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN u=10000 WHEN id=1 THEN u=0 ELSE u>1.2399 AND u<1.2401 END),'NULL') FROM poc.ff_after_insert ORDER BY id",
                    "1.00\t1\t1\t1\t1\t1\n2.00\t1\t1\t1\t1\t1\n3.00\t1\t1\t1\t1\tNULL\n4.00\tNULL\tNULL\tNULL\tNULL\tNULL"
                )),
            .init(
                id: "updated-field-values",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(10,2)),IFNULL((CASE WHEN id=10.26 THEN a> -100000 AND a< -99999 WHEN id=2 THEN a>1.2399 AND a<1.2401 ELSE a>1.2399 AND a<1.2401 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN b=0 ELSE b=-1.234568 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN c> -1.000001e-5 AND c< -9.99999e-6 ELSE c>0.09999999 AND c<0.10000001 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN d=-1e199 ELSE d=1e199 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN u=10000 WHEN id=1 THEN u=0 ELSE u>1.2399 AND u<1.2401 END),'NULL') FROM poc.ff_after_update ORDER BY id",
                    "2.00\t1\t1\t1\t1\t1\n3.00\t1\t1\t1\t1\tNULL\n4.00\tNULL\tNULL\tNULL\tNULL\tNULL\n10.26\t1\t1\t1\t1\t1"
                )),
            .init(
                id: "altered-field-values",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(10,2)),IFNULL((CASE WHEN id=10.26 THEN a> -100000 AND a< -99999 WHEN id=2 THEN a> -1.236 AND a< -1.233 ELSE a>1.2399 AND a<1.2401 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN b=0 ELSE b=-1.234568 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN c> -1.000001e-5 AND c< -9.99999e-6 ELSE c>0.09999999 AND c<0.10000001 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN d=-1e199 ELSE d=1e199 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN u=10000 WHEN id=1 THEN u=0 ELSE u>1.2399 AND u<1.2401 END),'NULL'),IFNULL((e=9.88),'NULL') FROM poc.ff_after_alter ORDER BY id",
                    "2.00\t1\t1\t1\t1\t1\t1\n3.00\t1\t1\t1\t1\tNULL\t1\n4.00\tNULL\tNULL\tNULL\tNULL\tNULL\t1\n10.26\t1\t1\t1\t1\t1\t1"
                )),
            .init(
                id: "final-null-row",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(10,2)),IFNULL((CASE WHEN id=10.26 THEN a> -100000 AND a< -99999 WHEN id=2 THEN a> -1.236 AND a< -1.233 ELSE a>1.2399 AND a<1.2401 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN b=0 ELSE b=-1.234568 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN c> -1.000001e-5 AND c< -9.99999e-6 ELSE c>0.09999999 AND c<0.10000001 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN d=-1e199 ELSE d=1e199 END),'NULL'),IFNULL((CASE WHEN id=10.26 THEN u=10000 WHEN id=1 THEN u=0 ELSE u>1.2399 AND u<1.2401 END),'NULL'),IFNULL((e=9.88),'NULL') FROM poc.matrix_fixedfloating ORDER BY id",
                    "4.00\tNULL\tNULL\tNULL\tNULL\tNULL\t1")),
            .init(
                id: "initial-stored-defaults",
                check: .init(
                    "SELECT (DEFAULT(a)>1.2399 AND DEFAULT(a)<1.2401),(DEFAULT(b)=-1.234568),(DEFAULT(c)>0.09999999 AND DEFAULT(c)<0.10000001),(DEFAULT(d)=1e199) FROM poc.ff_after_insert WHERE id=2",
                    "1\t1\t1\t1")),
            .init(
                id: "initial-declared-types",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ff_after_insert' ORDER BY ORDINAL_POSITION",
                    "id\tdouble(10,2)\tNO\na\tfloat(10,2)\tYES\nb\tdouble(20,6)\tYES\nc\tfloat(30,20)\tYES\nd\tdouble(200,0)\tYES\nu\tfloat(10,2) unsigned\tYES"
                )),
            .init(
                id: "altered-stored-defaults",
                check: .init(
                    "SELECT (DEFAULT(a)> -1.236 AND DEFAULT(a)< -1.233),(DEFAULT(b)=-1.234568),(DEFAULT(c)>0.09999999 AND DEFAULT(c)<0.10000001),(DEFAULT(d)=1e199),(DEFAULT(e)=9.88) FROM poc.ff_after_alter WHERE id=2",
                    "1\t1\t1\t1\t1")),
            .init(
                id: "altered-declared-types",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ff_after_alter' ORDER BY ORDINAL_POSITION",
                    "id\tdouble(10,2)\tNO\na\tfloat(12,3)\tYES\nb\tdouble(20,6)\tYES\nc\tfloat(30,20)\tYES\nd\tdouble(200,0)\tYES\nu\tfloat(10,2) unsigned\tYES\ne\tdouble(10,2)\tYES"
                )),
        ], expectedDDL: 6, expectedRows: 24)

    static let floating = DMLExecutionWorkflow(
        title: "Floating-point types: FLOAT and DOUBLE ranges, defaults and changes",
        histories: [
            .init(table: "fl_after_insert", throughPhase: 1),
            .init(table: "fl_after_key_update", throughPhase: 2),
            .init(table: "fl_after_max_update", throughPhase: 3),
            .init(table: "fl_after_alter", throughPhase: 4),
        ], phaseTransactions: [1, 1, 1, 2, 1],
        predicateIDs: [
            "inserted-float-double-and-null", "changed-double-key-and-subnormal-values", "updated-maximum-values",
            "changed-float-precision-and-added-double", "deleted-non-null-rows",
        ],
        additionalChecks: [
            .init(
                id: "initial-field-values",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a> -0.10000001 AND a< -0.09999999 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=-1e-1 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1 END),'NULL') FROM poc.fl_after_insert ORDER BY id",
                    "0.00\t1\t1\t1\n1.00\t1\t1\t1\n2.00\t1\t1\tNULL\n3.00\t1\t1\t1\n4.00\tNULL\tNULL\tNULL")),
            .init(
                id: "subnormal-field-values",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a> -0.10000001 AND a< -0.09999999 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=-1e-1 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1 END),'NULL') FROM poc.fl_after_key_update ORDER BY id",
                    "0.00\t1\t1\t1\n2.00\t1\t1\tNULL\n3.00\t1\t1\t1\n4.00\tNULL\tNULL\tNULL\n10.25\t1\t1\t1")),
            .init(
                id: "maximum-field-values",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a>3.4028234e38 AND a<3.4028235e38 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=1.7976931348623157e308 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1 END),'NULL') FROM poc.fl_after_max_update ORDER BY id",
                    "0.00\t1\t1\t1\n2.00\t1\t1\tNULL\n3.00\t1\t1\t1\n4.00\tNULL\tNULL\tNULL\n10.25\t1\t1\t1")),
            .init(
                id: "altered-field-values",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a>3.4028234e38 AND a<3.4028235e38 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=1.7976931348623157e308 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1e-1 END),'NULL'),IFNULL((CASE WHEN id=3 THEN d=-1.25e12 ELSE d=1.25e-2 END),'NULL') FROM poc.fl_after_alter ORDER BY id",
                    "0.00\t1\t1\t1\t1\n2.00\t1\t1\tNULL\t1\n3.00\t1\t1\t1\t1\n4.00\tNULL\tNULL\tNULL\t1\n10.25\t1\t1\t1\t1"
                )),
            .init(
                id: "final-null-row",
                check: .init(
                    "SELECT CAST(id AS DECIMAL(5,2)),IFNULL((CASE WHEN id=0 THEN a=0 WHEN id=1 THEN a>0.09999999 AND a<0.10000001 WHEN id=10.25 THEN a>1.4012984e-45 AND a<1.4012985e-45 WHEN id=2 THEN a>3.4028234e38 AND a<3.4028235e38 ELSE a>1.1754943e-38 AND a<1.1754944e-38 END),'NULL'),IFNULL((CASE WHEN id=0 THEN b=0 WHEN id=1 THEN b=1e-1 WHEN id=10.25 THEN b=4.9406564584124654e-324 WHEN id=2 THEN b=1.7976931348623157e308 ELSE b=2.2250738585072014e-308 END),'NULL'),IFNULL((CASE WHEN id=0 THEN c=0 WHEN id=1 THEN c=0.125 WHEN id=10.25 THEN c>1.23456 AND c<1.23458 ELSE c=1e-1 END),'NULL'),IFNULL((CASE WHEN id=3 THEN d=-1.25e12 ELSE d=1.25e-2 END),'NULL') FROM poc.matrix_floating ORDER BY id",
                    "4.00\tNULL\tNULL\tNULL\t1")),
            .init(
                id: "initial-stored-defaults",
                check: .init(
                    "SELECT (DEFAULT(c)>1.23456 AND DEFAULT(c)<1.23458) FROM poc.fl_after_insert WHERE id=4", "1")),
            .init(
                id: "initial-declared-types",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='fl_after_insert' ORDER BY ORDINAL_POSITION",
                    "id\tdouble\tNO\na\tfloat\tYES\nb\tdouble\tYES\nc\tfloat unsigned\tYES")),
            .init(
                id: "altered-stored-defaults",
                check: .init(
                    "SELECT (DEFAULT(c)=0.125),(DEFAULT(d)=1.25e-2) FROM poc.fl_after_alter WHERE id=4", "1\t1")),
            .init(
                id: "altered-declared-types",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='fl_after_alter' ORDER BY ORDINAL_POSITION",
                    "id\tdouble\tNO\na\tfloat\tYES\nb\tdouble\tYES\nc\tdouble unsigned\tYES\nd\tdouble\tYES")),
        ], expectedDDL: 7, expectedRows: 38)
}
