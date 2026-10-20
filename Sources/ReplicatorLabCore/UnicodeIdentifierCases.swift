import Foundation

extension DMLCompatibilityCases {
    static let unicodeIdentifiers: Case = {
        let long = String(repeating: "中", count: 64)
        return Case(
            id: "unicodeidentifiers",
            definition:
                "id INT PRIMARY KEY,`é` INT DEFAULT 10,`e\u{0301}` INT DEFAULT 20,值 INT,`a``b` INT,`\(long)` INT,KEY `é`(`é`,id),KEY `e\u{0301}`(`e\u{0301}`,id)",
            phases: [
                .init(
                    sql:
                        "INSERT INTO poc.matrix_unicodeidentifiers(id,值,`a``b`,`\(long)`) VALUES(1,30,40,50),(2,NULL,NULL,NULL)",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=1 AND `é`=10 AND `e\u{0301}`=20 AND 值=30 AND `a``b`=40 AND `\(long)`=50"
                ),
                .init(
                    sql:
                        "UPDATE poc.matrix_unicodeidentifiers SET `É`=11,`e\u{0301}`=21,值=31 WHERE id=1; ALTER TABLE poc.matrix_unicodeidentifiers ADD 列 INT DEFAULT 7 AFTER 值",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=1 AND `é`=11 AND `e\u{0301}`=21 AND 值=31 AND 列=7"
                ),
                .init(
                    sql:
                        "ALTER TABLE poc.matrix_unicodeidentifiers CHANGE `É` 改名 BIGINT DEFAULT 15; ALTER TABLE poc.matrix_unicodeidentifiers RENAME INDEX `É` TO 键; UPDATE poc.matrix_unicodeidentifiers SET 改名=DEFAULT,`a``b`=41 WHERE id=2",
                    check:
                        "SELECT COUNT(*)=1 FROM poc.matrix_unicodeidentifiers WHERE id=2 AND 改名=15 AND `e\u{0301}`=20 AND `a``b`=41"
                ),
                .init(
                    sql:
                        "ALTER TABLE poc.matrix_unicodeidentifiers DROP INDEX 键, DROP COLUMN 列; DELETE FROM poc.matrix_unicodeidentifiers WHERE id=1",
                    check: "SELECT COUNT(*)=1 AND SUM(改名)=15 FROM poc.matrix_unicodeidentifiers"),
            ])
    }()
}

extension DDLCompatibilityCases {
    static let unicodeNames = Case(
        "unicode-names", "Separate Unicode table names, native case rules, rename and exact cache identity",
        [
            .init("CREATE TABLE ddlcompat.`é`(id INT PRIMARY KEY,值 INT)"),
            .init("CREATE TABLE ddlcompat.`e\u{0301}`(id INT PRIMARY KEY,值 INT)"),
            .init("INSERT INTO ddlcompat.`é` VALUES(1,10)"),
            .init("INSERT INTO ddlcompat.`e\u{0301}` VALUES(1,20)"),
            .init(
                "UPDATE ddlcompat.`é` SET 值=11 WHERE id=1",
                [.init("SELECT 值 FROM ddlcompat.`é`", "11"), .init("SELECT 值 FROM ddlcompat.`e\u{0301}`", "20")]),
            .init("RENAME TABLE ddlcompat.`é` TO ddlcompat.中"),
            .init("INSERT INTO ddlcompat.中 VALUES(2,12)", [.init("SELECT 值 FROM ddlcompat.中 ORDER BY id", "11\n12")]),
            .init("DROP TABLE ddlcompat.`e\u{0301}`"),
            .init("CREATE TABLE ddlcompat.`select` LIKE ddlcompat.中"),
            .init("INSERT INTO ddlcompat.`select` VALUES(1,30)"),
            .init("DROP TABLE ddlcompat.中"),
            .init("DROP TABLE ddlcompat.`select`"),
            .init("CREATE TABLE ddlcompat.`😀`(id INT PRIMARY KEY,`😀` INT)"),
            .init("INSERT INTO ddlcompat.`😀` VALUES(1,40)", [.init("SELECT `?` FROM ddlcompat.`?`", "40")]),
            .init("DROP TABLE ddlcompat.😀"),
        ])
}
