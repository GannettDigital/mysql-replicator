import Foundation

/// Retain numeric results until the shared applier completes each source batch.
enum DMLNumericWorkflows {
    static let integers = DMLExecutionWorkflow(
        title: "Integer types: signed and unsigned limits, key changes and NULL",
        histories: [
            .init(table: "iv_after_insert", throughPhase: 1),
            .init(table: "iv_after_update", throughPhase: 2),
        ], phaseTransactions: [1, 1, 1],
        predicateIDs: ["inserted-integer-limits", "changed-signed-key-and-null", "deleted-unaffected-row"],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL'),IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(e AS CHAR),'NULL'),IFNULL(CAST(f AS CHAR),'NULL') FROM poc.iv_after_insert ORDER BY id",
                    "-128\t-128\t255\t-32768\t65535\t-8388608\t16777215\n127\t127\t0\t32767\t0\t8388607\t0")),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL'),IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(e AS CHAR),'NULL'),IFNULL(CAST(f AS CHAR),'NULL') FROM poc.iv_after_update ORDER BY id",
                    "0\tNULL\t1\t-1\t1\t-1\t1\n127\t127\t0\t32767\t0\t8388607\t0")),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL'),IFNULL(CAST(d AS CHAR),'NULL'),IFNULL(CAST(e AS CHAR),'NULL'),IFNULL(CAST(f AS CHAR),'NULL') FROM poc.matrix_integers ORDER BY id",
                    "0\tNULL\t1\t-1\t1\t-1\t1")),
        ], expectedDDL: 3, expectedRows: 9)

    static let decimal = DMLExecutionWorkflow(
        title: "Fixed-point types: DECIMAL precision, scale, limits and NULL",
        histories: [
            .init(table: "dv_after_insert", throughPhase: 1),
            .init(table: "dv_after_update", throughPhase: 2),
        ], phaseTransactions: [1, 1, 1],
        predicateIDs: ["inserted-exact-decimals", "updated-maximum-and-null", "deleted-zero-row"],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL') FROM poc.dv_after_insert ORDER BY id",
                    "1\t-12345678901234567890123456789012345.123456789012345678901234567890\t99999999.99\t-0.9999\n2\t0.000000000000000000000000000000\t0.00\t0.0000"
                )),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL') FROM poc.dv_after_update ORDER BY id",
                    "1\t99999999999999999999999999999999999.999999999999999999999999999999\tNULL\t0.0001\n2\t0.000000000000000000000000000000\t0.00\t0.0000"
                )),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT id,IFNULL(CAST(a AS CHAR),'NULL'),IFNULL(CAST(b AS CHAR),'NULL'),IFNULL(CAST(c AS CHAR),'NULL') FROM poc.matrix_decimal ORDER BY id",
                    "1\t99999999999999999999999999999999999.999999999999999999999999999999\tNULL\t0.0001")),
        ], expectedDDL: 3, expectedRows: 9)

    static let bits = DMLExecutionWorkflow(
        title: "Bit-value type: widths through 64 bits, key changes and defaults",
        histories: [
            .init(table: "bv_after_insert", throughPhase: 1),
            .init(table: "bv_after_update", throughPhase: 2),
            .init(table: "bv_after_widen", throughPhase: 3),
        ], phaseTransactions: [1, 1, 2, 1],
        predicateIDs: [
            "inserted-bit-limits", "changed-bit-key-and-values", "widened-bit-and-added-default",
            "deleted-non-null-rows",
        ],
        additionalChecks: [
            .init(
                id: "initial-rows",
                check: .init(
                    "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS UNSIGNED),'NULL'),IFNULL(CAST(c AS UNSIGNED),'NULL'),IFNULL(CAST(d AS UNSIGNED),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL') FROM poc.bv_after_insert ORDER BY id",
                    "0\t0\t0\t0\t0\t0\n9223372036854775808\tNULL\tNULL\tNULL\tNULL\tNULL\n18446744073709551615\t1\t127\t255\t511\t9223372036854775807"
                )),
            .init(
                id: "updated-rows",
                check: .init(
                    "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS UNSIGNED),'NULL'),IFNULL(CAST(c AS UNSIGNED),'NULL'),IFNULL(CAST(d AS UNSIGNED),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL') FROM poc.bv_after_update ORDER BY id",
                    "72623859790382856\t1\t64\t128\t256\t4611686018427387904\n9223372036854775808\tNULL\tNULL\tNULL\tNULL\tNULL\n18446744073709551615\t1\t127\t255\t511\t9223372036854775807"
                )),
            .init(
                id: "widened-rows",
                check: .init(
                    "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS UNSIGNED),'NULL'),IFNULL(CAST(c AS UNSIGNED),'NULL'),IFNULL(CAST(d AS UNSIGNED),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL') FROM poc.bv_after_widen ORDER BY id",
                    "72623859790382856\t1\t64\t128\t256\t4611686018427387904\t255\n9223372036854775808\tNULL\tNULL\tNULL\tNULL\tNULL\t255\n18446744073709551615\t1\t127\t255\t65535\t9223372036854775807\t255"
                )),
            .init(
                id: "final-rows",
                check: .init(
                    "SELECT IFNULL(CAST(id AS UNSIGNED),'NULL'),IFNULL(CAST(a AS UNSIGNED),'NULL'),IFNULL(CAST(b AS UNSIGNED),'NULL'),IFNULL(CAST(c AS UNSIGNED),'NULL'),IFNULL(CAST(d AS UNSIGNED),'NULL'),IFNULL(CAST(e AS UNSIGNED),'NULL'),IFNULL(CAST(f AS UNSIGNED),'NULL') FROM poc.matrix_bits ORDER BY id",
                    "9223372036854775808\tNULL\tNULL\tNULL\tNULL\tNULL\t255")),
            .init(
                id: "initial-bit-declarations",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='bv_after_insert' ORDER BY ORDINAL_POSITION",
                    "id\tbit(64)\tNO\t1\na\tbit(1)\tYES\t0\nb\tbit(7)\tYES\t1\nc\tbit(8)\tYES\t1\nd\tbit(9)\tYES\t1\ne\tbit(63)\tYES\t1"
                )),
            .init(
                id: "initial-bit-defaults",
                check: .init("SELECT CAST(DEFAULT(a) AS UNSIGNED) FROM poc.bv_after_insert WHERE id=0", "1")),
            .init(
                id: "widened-bit-declarations",
                check: .init(
                    "SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT IS NULL FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='bv_after_widen' ORDER BY ORDINAL_POSITION",
                    "id\tbit(64)\tNO\t1\na\tbit(1)\tYES\t0\nb\tbit(7)\tYES\t1\nc\tbit(8)\tYES\t1\nd\tbit(16)\tYES\t0\ne\tbit(63)\tYES\t1\nf\tbit(8)\tYES\t0"
                )),
            .init(
                id: "widened-bit-defaults",
                check: .init(
                    "SELECT CAST(DEFAULT(a) AS UNSIGNED),CAST(DEFAULT(d) AS UNSIGNED),CAST(DEFAULT(f) AS UNSIGNED) FROM poc.bv_after_widen WHERE id=72623859790382856",
                    "1\t256\t255")),
        ], expectedDDL: 6, expectedRows: 19)
}
