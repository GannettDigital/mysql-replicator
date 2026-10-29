import Foundation

extension DDLCompatibilityCases {
    static let generatedColumns = Case(
        "generated", "Generated columns: stored and virtual values",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT,doubled INT GENERATED ALWAYS AS (n*2) STORED,added INT AS (n+1) VIRTUAL)"
            ),
            .init("INSERT INTO ddlcompat.t(id,n) VALUES(1,7),(2,NULL)"),
            .init("UPDATE ddlcompat.t SET n=9 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.t ADD next_value INT AS (n+2) STORED"),
            .init("INSERT INTO ddlcompat.t(id,n) VALUES(3,11)"),
            .init("DELETE FROM ddlcompat.t WHERE id=1"),
            .init("DELETE FROM ddlcompat.t WHERE id=2"),
            .init(
                "CREATE TABLE ddlcompat.gc_inserted(id INT PRIMARY KEY,n INT,doubled INT GENERATED ALWAYS AS (n*2) STORED,added INT AS (n+1) VIRTUAL)"
            ),
            .init("INSERT INTO ddlcompat.gc_inserted(id,n) VALUES(1,7),(2,NULL)"),
            .init(
                "CREATE TABLE ddlcompat.gc_updated(id INT PRIMARY KEY,n INT,doubled INT GENERATED ALWAYS AS (n*2) STORED,added INT AS (n+1) VIRTUAL)"
            ),
            .init("INSERT INTO ddlcompat.gc_updated(id,n) VALUES(1,7),(2,NULL)"),
            .init("UPDATE ddlcompat.gc_updated SET n=9 WHERE id=1"),
            .init(
                "CREATE TABLE ddlcompat.gc_added(id INT PRIMARY KEY,n INT,doubled INT GENERATED ALWAYS AS (n*2) STORED,added INT AS (n+1) VIRTUAL)"
            ),
            .init("INSERT INTO ddlcompat.gc_added(id,n) VALUES(1,7),(2,NULL)"),
            .init("UPDATE ddlcompat.gc_added SET n=9 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gc_added ADD next_value INT AS (n+2) STORED"),
            .init("INSERT INTO ddlcompat.gc_added(id,n) VALUES(3,11)"),
            .init(
                "CREATE TABLE ddlcompat.gc_deleted(id INT PRIMARY KEY,n INT,doubled INT GENERATED ALWAYS AS (n*2) STORED,added INT AS (n+1) VIRTUAL)"
            ),
            .init("INSERT INTO ddlcompat.gc_deleted(id,n) VALUES(1,7),(2,NULL)"),
            .init("UPDATE ddlcompat.gc_deleted SET n=9 WHERE id=1"),
            .init("ALTER TABLE ddlcompat.gc_deleted ADD next_value INT AS (n+2) STORED"),
            .init("INSERT INTO ddlcompat.gc_deleted(id,n) VALUES(3,11)"),
            .init("DELETE FROM ddlcompat.gc_deleted WHERE id=1", phaseEnd: "write-and-retain-results"),
        ],
        finalObservations: .init(
            checks: [
                .init(
                    id: "generated-insert-values",
                    check: .init("SELECT * FROM ddlcompat.gc_inserted ORDER BY id", "1\t7\t14\t8\n2\tNULL\tNULL\tNULL")),
                .init(
                    id: "generated-update-values",
                    check: .init("SELECT * FROM ddlcompat.gc_updated WHERE id=1", "1\t9\t18\t10")),
                .init(
                    id: "added-column-existing-values",
                    check: .init(
                        "SELECT * FROM ddlcompat.gc_added WHERE id IN (1,2) ORDER BY id",
                        "1\t9\t18\t10\t11\n2\tNULL\tNULL\tNULL\tNULL")),
                .init(
                    id: "insert-after-add",
                    check: .init("SELECT * FROM ddlcompat.gc_added WHERE id=3", "3\t11\t22\t12\t13")),
                .init(
                    id: "generated-delete-retains-null",
                    check: .init(
                        "SELECT * FROM ddlcompat.gc_deleted ORDER BY id", "2\tNULL\tNULL\tNULL\tNULL\n3\t11\t22\t12\t13"
                    )),
                .init(id: "final-row-count", check: .init("SELECT COUNT(*) FROM ddlcompat.t", "1")),
                .init(id: "final-generated-values", check: .init("SELECT * FROM ddlcompat.t", "3\t11\t22\t12\t13")),
                .init(
                    id: "initial-storage-forms",
                    check: .init(
                        "SELECT COLUMN_NAME,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='gc_inserted' AND EXTRA<>'' ORDER BY ORDINAL_POSITION",
                        "doubled\tSTORED GENERATED\nadded\tVIRTUAL GENERATED")),
                .init(
                    id: "added-storage-form",
                    check: .init(
                        "SELECT COLUMN_NAME,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='t' AND EXTRA<>'' ORDER BY ORDINAL_POSITION",
                        "doubled\tSTORED GENERATED\nadded\tVIRTUAL GENERATED\nnext_value\tSTORED GENERATED")),
            ], databases: ["ddlcompat"],
            cleanup: ["DROP TABLE ddlcompat.gc_inserted,ddlcompat.gc_updated,ddlcompat.gc_added,ddlcompat.gc_deleted"]))
}
