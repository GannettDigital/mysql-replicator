import Foundation

extension DMLCompatibilityCases {
    static let decimalDefaults = Case(
        id: "decimaldefaults",
        definition:
            "id INT PRIMARY KEY,a DECIMAL(8,2) DEFAULT 1.235,b DECIMAL(8,2) DEFAULT -1.235,c DECIMAL(8,2) DEFAULT 1.005e0,d DECIMAL(8,2) DEFAULT '1.005e0',z DECIMAL(8,2) ZEROFILL DEFAULT 9.999,u DECIMAL(8,2) UNSIGNED DEFAULT 0.005,n DECIMAL(8,0) DEFAULT -0.4",
        phases: [
            .init(
                sql: "INSERT INTO poc.matrix_decimaldefaults(id) VALUES(1),(2)",
                check:
                    "SELECT COUNT(*)=2 AND SUM(a=1.24 AND b=-1.24 AND c=1.01 AND d=1.01 AND z=10 AND u=0.01 AND n=0)=2 FROM poc.matrix_decimaldefaults"
            ),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_decimaldefaults ALTER a SET DEFAULT 2.345,ALTER b SET DEFAULT '-2.345',ALTER c SET DEFAULT 2.675e0,ADD extra DECIMAL(8,2) DEFAULT 9.995; UPDATE poc.matrix_decimaldefaults SET a=DEFAULT,b=DEFAULT,c=DEFAULT WHERE id=1",
                check:
                    "SELECT COUNT(*)=2 AND SUM(id=1 AND a=2.35 AND b=-2.35 AND c=2.68)=1 AND SUM(extra=10)=2 FROM poc.matrix_decimaldefaults"
            ),
            .init(
                sql:
                    "ALTER TABLE poc.matrix_decimaldefaults MODIFY d DECIMAL(10,3) DEFAULT '1.2345',ALTER u DROP DEFAULT; INSERT INTO poc.matrix_decimaldefaults(id,u) VALUES(3,NULL); DELETE FROM poc.matrix_decimaldefaults WHERE id=2",
                check:
                    "SELECT COUNT(*)=2 AND SUM(id=3 AND d=1.235 AND u IS NULL AND extra=10)=1 FROM poc.matrix_decimaldefaults"
            ),
        ],
        workflow: .init(
            title: "Fixed-point types: DECIMAL default rounding and scale changes",
            histories: [
                .init(table: "dd_after_insert", throughPhase: 1),
                .init(table: "dd_after_defaults", throughPhase: 2),
            ], phaseTransactions: [1, 2, 3],
            predicateIDs: [
                "inserted-rounded-defaults", "changed-defaults-and-added-column",
                "changed-scale-dropped-default-and-replaced-row",
            ],
            additionalChecks: [
                .init(
                    id: "initial-rows",
                    check: .init(
                        "SELECT id,IFNULL(CAST(a AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(d AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(z AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(u AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(n AS DECIMAL(8,0)),'NULL') FROM poc.dd_after_insert ORDER BY id",
                        "1\t1.24\t-1.24\t1.01\t1.01\t10.00\t0.01\t0\n2\t1.24\t-1.24\t1.01\t1.01\t10.00\t0.01\t0")),
                .init(
                    id: "initial-stored-defaults",
                    check: .init(
                        "SELECT IFNULL(CAST(DEFAULT(a) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(b) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(c) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(d) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(z) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(u) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(n) AS DECIMAL(8,0)),'NULL') FROM poc.dd_after_insert WHERE id=1",
                        "1.24\t-1.24\t1.01\t1.01\t10.00\t0.01\t0")),
                .init(
                    id: "initial-column-attributes",
                    check: .init(
                        "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='dd_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                        "a\tdecimal(8,2)\tYES\t0\nb\tdecimal(8,2)\tYES\t0\nc\tdecimal(8,2)\tYES\t0\nd\tdecimal(8,2)\tYES\t0\nz\tdecimal(8,2) unsigned zerofill\tYES\t0\nu\tdecimal(8,2) unsigned\tYES\t0\nn\tdecimal(8,0)\tYES\t0"
                    )),
                .init(
                    id: "changed-defaults-rows",
                    check: .init(
                        "SELECT id,IFNULL(CAST(a AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(d AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(z AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(u AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(n AS DECIMAL(8,0)),'NULL'),IFNULL(CAST(extra AS DECIMAL(8,2)),'NULL') FROM poc.dd_after_defaults ORDER BY id",
                        "1\t2.35\t-2.35\t2.68\t1.01\t10.00\t0.01\t0\t10.00\n2\t1.24\t-1.24\t1.01\t1.01\t10.00\t0.01\t0\t10.00"
                    )),
                .init(
                    id: "changed-defaults-stored-defaults",
                    check: .init(
                        "SELECT IFNULL(CAST(DEFAULT(a) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(b) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(c) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(d) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(z) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(u) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(n) AS DECIMAL(8,0)),'NULL'),IFNULL(CAST(DEFAULT(extra) AS DECIMAL(8,2)),'NULL') FROM poc.dd_after_defaults WHERE id=1",
                        "2.35\t-2.35\t2.68\t1.01\t10.00\t0.01\t0\t10.00")),
                .init(
                    id: "changed-defaults-column-attributes",
                    check: .init(
                        "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='dd_after_defaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                        "a\tdecimal(8,2)\tYES\t0\nb\tdecimal(8,2)\tYES\t0\nc\tdecimal(8,2)\tYES\t0\nd\tdecimal(8,2)\tYES\t0\nz\tdecimal(8,2) unsigned zerofill\tYES\t0\nu\tdecimal(8,2) unsigned\tYES\t0\nn\tdecimal(8,0)\tYES\t0\nextra\tdecimal(8,2)\tYES\t0"
                    )),
                .init(
                    id: "final-rows",
                    check: .init(
                        "SELECT id,IFNULL(CAST(a AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(b AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(c AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(d AS DECIMAL(10,3)),'NULL'),IFNULL(CAST(z AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(u AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(n AS DECIMAL(8,0)),'NULL'),IFNULL(CAST(extra AS DECIMAL(8,2)),'NULL') FROM poc.matrix_decimaldefaults ORDER BY id",
                        "1\t2.35\t-2.35\t2.68\t1.010\t10.00\t0.01\t0\t10.00\n3\t2.35\t-2.35\t2.68\t1.235\t10.00\tNULL\t0\t10.00"
                    )),
                .init(
                    id: "final-stored-defaults",
                    check: .init(
                        "SELECT IFNULL(CAST(DEFAULT(a) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(b) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(c) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(d) AS DECIMAL(10,3)),'NULL'),IFNULL(CAST(DEFAULT(z) AS DECIMAL(8,2)),'NULL'),IFNULL(CAST(DEFAULT(n) AS DECIMAL(8,0)),'NULL'),IFNULL(CAST(DEFAULT(extra) AS DECIMAL(8,2)),'NULL') FROM poc.matrix_decimaldefaults WHERE id=1",
                        "2.35\t-2.35\t2.68\t1.235\t10.00\t0\t10.00")),
                .init(
                    id: "final-column-attributes",
                    check: .init(
                        "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_decimaldefaults' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                        "a\tdecimal(8,2)\tYES\t0\nb\tdecimal(8,2)\tYES\t0\nc\tdecimal(8,2)\tYES\t0\nd\tdecimal(10,3)\tYES\t0\nz\tdecimal(8,2) unsigned zerofill\tYES\t0\nu\tdecimal(8,2) unsigned\tYES\t1\nn\tdecimal(8,0)\tYES\t0\nextra\tdecimal(8,2)\tYES\t0"
                    )),
            ], expectedDDL: 6, expectedRows: 10))
}
