import Foundation

/// Keep source session settings in their original requests and observe UTC values.
enum DMLTemporalWorkflows {
    static let temporal = DMLExecutionWorkflow(
        title: "Date and time types: time zones, range limits, zero values and NULL",
        histories: [
            .init(table: "tv_after_insert", throughPhase: 1),
            .init(table: "tv_after_update", throughPhase: 2),
        ], phaseTransactions: [1, 1, 1],
        predicateIDs: [
            "inserted-time-zone-and-range-values", "updated-timestamp-and-null-date", "deleted-zero-value-row",
        ],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(dt AS CHAR),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL'),IFNULL(CAST(t AS CHAR),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.tv_after_insert ORDER BY id",
                    "1\t2024-02-29\t9999-12-31 23:59:59.999999\t2024-02-29 00:00:00.123456\t-838:59:59.000000\t2155\n2\t0000-00-00\t0000-00-00 00:00:00.000000\t0000-00-00 00:00:00.000000\t-00:00:00.000001\t0"
                )),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(dt AS CHAR),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL'),IFNULL(CAST(t AS CHAR),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.tv_after_update ORDER BY id",
                    "1\tNULL\t9999-12-31 23:59:59.999999\t2038-01-19 03:14:07.999999\t838:59:59.000000\t1901\n2\t0000-00-00\t0000-00-00 00:00:00.000000\t0000-00-00 00:00:00.000000\t-00:00:00.000001\t0"
                )),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(dt AS CHAR),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL'),IFNULL(CAST(t AS CHAR),'NULL'),IFNULL(CAST(y AS UNSIGNED),'NULL') FROM poc.matrix_temporal ORDER BY id",
                    "1\tNULL\t9999-12-31 23:59:59.999999\t2038-01-19 03:14:07.999999\t838:59:59.000000\t1901")),
            .init(
                id: "declared-fractional-seconds",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,DATETIME_PRECISION,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='tv_after_insert' AND COLUMN_NAME IN ('dt','ts','t') ORDER BY ORDINAL_POSITION",
                    "dt\tdatetime(6)\t6\tYES\nts\ttimestamp(6)\t6\tYES\nt\ttime(6)\t6\tYES")),
        ], expectedDDL: 3, expectedRows: 9)

    static let precision = DMLExecutionWorkflow(
        title: "Fractional seconds: TIME, DATETIME and TIMESTAMP precision",
        histories: [
            .init(table: "tp_after_insert", throughPhase: 1)
        ], phaseTransactions: [1, 1],
        predicateIDs: ["inserted-fractional-second-values", "updated-fractional-time-and-null"],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(t0 AS CHAR),'NULL'),IFNULL(CAST(t1 AS CHAR),'NULL'),IFNULL(CAST(t2 AS CHAR),'NULL'),IFNULL(CAST(t3 AS CHAR),'NULL'),IFNULL(CAST(t4 AS CHAR),'NULL'),IFNULL(CAST(t5 AS CHAR),'NULL'),IFNULL(CAST(t6 AS CHAR),'NULL'),IFNULL(CAST(d0 AS CHAR),'NULL'),IFNULL(CAST(d3 AS CHAR),'NULL'),IFNULL(CAST(s0 AS CHAR),'NULL'),IFNULL(CAST(s3 AS CHAR),'NULL') FROM poc.tp_after_insert ORDER BY id",
                    "1\t-12:34:56\t-00:00:00.1\t-00:00:00.12\t-00:00:00.123\t-00:00:00.1234\t-00:00:00.12345\t-00:00:00.123456\t2024-01-01 12:34:56\t2024-01-01 12:34:56.789\t1970-01-01 00:00:01\t2024-01-01 12:34:56.789"
                )),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(t0 AS CHAR),'NULL'),IFNULL(CAST(t1 AS CHAR),'NULL'),IFNULL(CAST(t2 AS CHAR),'NULL'),IFNULL(CAST(t3 AS CHAR),'NULL'),IFNULL(CAST(t4 AS CHAR),'NULL'),IFNULL(CAST(t5 AS CHAR),'NULL'),IFNULL(CAST(t6 AS CHAR),'NULL'),IFNULL(CAST(d0 AS CHAR),'NULL'),IFNULL(CAST(d3 AS CHAR),'NULL'),IFNULL(CAST(s0 AS CHAR),'NULL'),IFNULL(CAST(s3 AS CHAR),'NULL') FROM poc.matrix_precision ORDER BY id",
                    "1\t-12:34:56\t12:34:56.1\t-00:00:00.12\t-00:00:00.123\t-00:00:00.1234\t-00:00:00.12345\t00:00:00.000000\t2024-01-01 12:34:56\tNULL\t1970-01-01 00:00:01\t2024-01-01 12:34:56.789"
                )),
            .init(
                id: "declared-fractional-seconds",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,DATETIME_PRECISION,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='tp_after_insert' AND COLUMN_NAME<>'id' ORDER BY ORDINAL_POSITION",
                    "t0\ttime\t0\tYES\nt1\ttime(1)\t1\tYES\nt2\ttime(2)\t2\tYES\nt3\ttime(3)\t3\tYES\nt4\ttime(4)\t4\tYES\nt5\ttime(5)\t5\tYES\nt6\ttime(6)\t6\tYES\nd0\tdatetime\t0\tYES\nd3\tdatetime(3)\t3\tYES\ns0\ttimestamp\t0\tYES\ns3\ttimestamp(3)\t3\tYES"
                )),
        ], expectedDDL: 2, expectedRows: 3)

    static let defaults = DMLExecutionWorkflow(
        title: "Automatic column values: generated IDs, defaults and TIMESTAMP updates",
        histories: [
            .init(table: "av_after_insert", throughPhase: 1),
            .init(table: "av_after_update", throughPhase: 2),
        ], phaseTransactions: [1, 1, 1],
        predicateIDs: [
            "inserted-generated-ids-and-defaults", "updated-automatic-timestamp", "inserted-explicit-zero-and-null",
        ],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(v AS CHAR),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL') FROM poc.av_after_insert ORDER BY id",
                    "1\t7\t73656564\t2023-11-14 22:13:20.123456\n2\t7\t6578706C69636974\t2023-11-14 22:13:20.123456")),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(v AS CHAR),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL') FROM poc.av_after_update ORDER BY id",
                    "1\t9\t73656564\t2023-11-14 22:13:21.654321\n2\t7\t6578706C69636974\t2023-11-14 22:13:20.123456")),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(v AS CHAR),'NULL'),IFNULL(HEX(s),'NULL'),IFNULL(CAST(ts AS CHAR),'NULL') FROM poc.matrix_defaults ORDER BY id",
                    "0\t0\t7A65726F\tNULL\n1\t9\t73656564\t2023-11-14 22:13:21.654321\n2\t7\t6578706C69636974\t2023-11-14 22:13:20.123456\n20\t20\t6578706C69636974\tNULL"
                )),
            .init(
                id: "automatic-column-attributes",
                check: .init(
                    "SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE,EXTRA LIKE '%auto_increment%' FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='av_after_update' ORDER BY ORDINAL_POSITION",
                    "id\tint\tNO\t1\nv\tint\tNO\t0\ns\tvarchar\tYES\t0\nts\ttimestamp\tYES\t0")),
            .init(
                id: "automatic-timestamp-default-and-update",
                check: .init(
                    "SELECT DATETIME_PRECISION,LOWER(COLUMN_DEFAULT)='current_timestamp(6)',LOWER(EXTRA) LIKE '%on update current_timestamp(6)%' FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='av_after_update' AND COLUMN_NAME='ts'",
                    "6\t1\t1")),
            .init(
                id: "constant-stored-defaults",
                check: .init("SELECT DEFAULT(v),HEX(DEFAULT(s)) FROM poc.av_after_update WHERE id=1", "7\t73656564")),
        ], expectedDDL: 3, expectedRows: 10)
}
