import Foundation

extension DDLCompatibilityCases {
    static let generatedDependencies = Case(
        "generated-dependencies",
        "Generated dependency replacement, rename, stored/base conversion, restart and replay",
        [
            .init(
                "CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED,h INT AS(g*2) VIRTUAL,literal_text VARCHAR(10) AS('`a`') STORED,KEY by_g(g))"
            ),
            .init("INSERT INTO ddlcompat.t(id,a) VALUES(1,5)", phaseEnd: "generated-chain-seed"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE a b INT,MODIFY g INT AS(b+2) STORED",
                [
                    .init("SELECT b,g,h,literal_text FROM ddlcompat.t", "5\t7\t14\t`a`")
                ], phaseEnd: "base-rename-and-expression-replacement"),
            .init(
                "UPDATE ddlcompat.t SET b=6 WHERE id=1", [.init("SELECT g,h FROM ddlcompat.t", "8\t16")],
                restartBefore: true, phaseEnd: "replaced-expression-update-after-resume"),
            .init(
                "ALTER TABLE ddlcompat.t MODIFY g INT AS(c+3) STORED,CHANGE b c INT",
                [
                    .init("SELECT c,g,h FROM ddlcompat.t", "6\t9\t18")
                ], phaseEnd: "expression-before-base-rename"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE g new_g INT AS(c+3) STORED,MODIFY h INT AS(new_g*3) VIRTUAL",
                phaseEnd: "generated-column-rename"),
            .init(
                "UPDATE ddlcompat.t SET c=7 WHERE id=1", [.init("SELECT new_g,h FROM ddlcompat.t", "10\t30")],
                restartBefore: true, phaseEnd: "renamed-generated-update-after-resume"),
            .init(
                "ALTER TABLE ddlcompat.t CHANGE c d INT,DROP h,MODIFY new_g INT AS(d+4) STORED",
                [
                    .init("SELECT d,new_g FROM ddlcompat.t", "7\t11")
                ], phaseEnd: "drop-dependent-column"),
            .init(
                "ALTER TABLE ddlcompat.t MODIFY new_g INT", [.init("SELECT new_g FROM ddlcompat.t", "11")],
                phaseEnd: "stored-to-base-conversion"),
            .init("UPDATE ddlcompat.t SET new_g=12 WHERE id=1", restartBefore: true),
            .init(
                "ALTER TABLE ddlcompat.t MODIFY d INT AS(id+3) STORED",
                [.init("SELECT d,new_g FROM ddlcompat.t", "4\t12")], phaseEnd: "base-to-stored-conversion"),
            .init(
                "UPDATE ddlcompat.t SET id=2 WHERE id=1", [.init("SELECT d,new_g FROM ddlcompat.t", "5\t12")],
                restartBefore: true, phaseEnd: "converted-column-update-after-resume"),
            .init("CREATE TABLE ddlcompat.q(id INT PRIMARY KEY,a INT,g INT AS(a+1) STORED)"),
            .init("INSERT INTO ddlcompat.q(id,a) VALUES(1,8)", phaseEnd: "independent-generated-seed"),
            .init(
                "ALTER TABLE ddlcompat.q CHANGE a b INT,DROP g", [.init("SELECT id,b FROM ddlcompat.q", "1\t8")],
                phaseEnd: "rename-and-drop-dependent-column"),
            .init("ALTER TABLE ddlcompat.q ADD g INT AS(b*2) STORED", phaseEnd: "recreate-generated-column"),
            .init("ALTER TABLE ddlcompat.q DROP g,CHANGE b c INT"),
            .init("UPDATE ddlcompat.q SET c=9 WHERE id=1", phaseEnd: "drop-and-rename-following-update"),
            .init("CREATE TABLE ddlcompat.l(id INT PRIMARY KEY,a INT,g VARCHAR(10) AS('`a`') STORED)"),
            .init("INSERT INTO ddlcompat.l(id,a) VALUES(1,10)", phaseEnd: "quoted-identifier-literal-seed"),
            .init(
                "ALTER TABLE ddlcompat.l CHANGE a b INT", [.init("SELECT b,g FROM ddlcompat.l", "10\t`a`")],
                phaseEnd: "quoted-identifier-literal-after-rename"),
            .init("DELETE FROM ddlcompat.l WHERE id=1", phaseEnd: "literal-row-delete"),
            .init("DROP TABLE ddlcompat.t,ddlcompat.q,ddlcompat.l", phaseEnd: "drop-generated-tables"),
        ])
}
