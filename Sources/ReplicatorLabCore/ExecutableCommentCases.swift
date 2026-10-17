import Foundation

extension DDLCompatibilityCases {
    static let executableComments = Case(
        "executable-comments", "Version comments retain target SQL, metadata, rows, restart and replay",
        [
            .init(
                "/*!50700 CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT DEFAULT 3,note VARCHAR(40) DEFAULT '/*! keep */') */"
            ),
            .init("INSERT INTO ddlcompat.t(id) VALUES(1)"),
            .init("ALTER TABLE ddlcompat.t /*!50700 ADD extra INT DEFAULT 7 */", restartBefore: true),
            .init(
                "UPDATE ddlcompat.t SET n=4 WHERE id=1",
                [.init("SELECT id,n,note,extra FROM ddlcompat.t", "1\t4\t/*! keep */\t7")]),
            .init("ALTER TABLE ddlcompat.t ADD last_col INT DEFAULT 9 /*!99999 , ADD future_col INT */"),
            .init("/*! ALTER TABLE ddlcompat.t MODIFY last_col BIGINT DEFAULT 9 */", restartBefore: true),
            .init("INSERT INTO ddlcompat.t(id) VALUES(2)"),
            .init(
                "DELETE FROM ddlcompat.t WHERE id=1",
                [.init("SELECT id,n,extra,last_col FROM ddlcompat.t", "2\t3\t7\t9")]),
        ])
    static let executableCommentsTargetGate = Case(
        "executable-comments-target-gate", "An inactive whole DDL reaches 5.7 unchanged and leaves metadata intact",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
            .init("/*!80400 ALTER TABLE ddlcompat.t COMMENT='source-only' */", restartBefore: true),
            .init("INSERT INTO ddlcompat.t VALUES(1,2)"),
            .init("UPDATE ddlcompat.t SET n=3 WHERE id=1", [.init("SELECT id,n FROM ddlcompat.t", "1\t3")]),
        ],
        profileExclusions: [
            .reverse: "Requires an 8.4 source and a 5.7 target.",
            .mysql57MyISAM: "Requires an 8.4 source and a 5.7 target.",
            .mysql57InnoDB: "Requires an 8.4 source and a 5.7 target.",
        ])
    static let executableCommentsSourceGate = Case(
        "executable-comments-source-gate", "A comment disabled by 5.7 stays inactive on the target",
        [
            .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY)"),
            .init("ALTER TABLE ddlcompat.t ADD n INT DEFAULT 7 /*!80000 , ADD future_col INT */", restartBefore: true),
            .init("INSERT INTO ddlcompat.t VALUES(1,8)"),
            .init("UPDATE ddlcompat.t SET n=9 WHERE id=1", [.init("SELECT id,n FROM ddlcompat.t", "1\t9")]),
        ], profileExclusions: [.forward: "This case tests a comment disabled by the 5.7 source."])
}
