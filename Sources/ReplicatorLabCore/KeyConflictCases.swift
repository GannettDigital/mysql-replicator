import Foundation

extension DDLCompatibilityCases {
    static let keyConflicts = Case(
        "key-conflicts", "INSERT ON DUPLICATE KEY UPDATE, REPLACE and INSERT IGNORE with PRIMARY/UNIQUE keys",
        [
            .init(
                "CREATE TABLE ddlcompat.insert_on_duplicate(id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin",
                assertionID: "upsert-table-create"),
            .init(
                "INSERT INTO ddlcompat.insert_on_duplicate VALUES(1,10),(2,20)",
                [.init("SELECT id,v FROM ddlcompat.insert_on_duplicate ORDER BY id", "1\t10\n2\t20")], transactions: 1,
                assertionID: "insert-on-duplicate-seed"),
            .init(
                "INSERT INTO ddlcompat.insert_on_duplicate VALUES(1,11),(3,30) ON DUPLICATE KEY UPDATE v=VALUES(v)",
                [.init("SELECT id,v FROM ddlcompat.insert_on_duplicate ORDER BY id", "1\t11\n2\t20\n3\t30")],
                transactions: 1, assertionID: "insert-on-duplicate-mixed"),
            .init(
                "INSERT INTO ddlcompat.insert_on_duplicate VALUES(1,11) ON DUPLICATE KEY UPDATE v=VALUES(v)",
                [.init("SELECT id,v FROM ddlcompat.insert_on_duplicate ORDER BY id", "1\t11\n2\t20\n3\t30")],
                transactions: 0, assertionID: "insert-on-duplicate-noop"),
            .init(
                "CREATE TABLE ddlcompat.replace_rows(id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin",
                assertionID: "replace-table-create"),
            .init(
                "INSERT INTO ddlcompat.replace_rows VALUES(1,10),(2,20)",
                [.init("SELECT id,v FROM ddlcompat.replace_rows ORDER BY id", "1\t10\n2\t20")], transactions: 1,
                assertionID: "replace-seed"),
            .init(
                "REPLACE INTO ddlcompat.replace_rows VALUES(1,20),(3,30)",
                [.init("SELECT id,v FROM ddlcompat.replace_rows ORDER BY id", "1\t20\n3\t30")], transactions: 1,
                assertionID: "replace-primary-and-unique-conflicts"),
            .init(
                "CREATE TABLE ddlcompat.insert_ignore(id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin",
                assertionID: "ignore-table-create"),
            .init(
                "INSERT INTO ddlcompat.insert_ignore VALUES(1,10)",
                [.init("SELECT id,v FROM ddlcompat.insert_ignore ORDER BY id", "1\t10")], transactions: 1,
                assertionID: "insert-ignore-seed"),
            .init(
                "INSERT IGNORE INTO ddlcompat.insert_ignore VALUES(1,11),(2,20),(3,10)",
                [.init("SELECT id,v FROM ddlcompat.insert_ignore ORDER BY id", "1\t10\n2\t20")], transactions: 1,
                assertionID: "insert-ignore-mixed-conflicts"),
            .init(
                "INSERT IGNORE INTO ddlcompat.insert_ignore VALUES(1,99)",
                [.init("SELECT id,v FROM ddlcompat.insert_ignore ORDER BY id", "1\t10\n2\t20")], transactions: 0,
                assertionID: "insert-ignore-noop"),
        ])
}
