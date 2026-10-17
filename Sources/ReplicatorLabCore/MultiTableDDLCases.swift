import Foundation

extension DDLCompatibilityCases {
    static let multiTableDDL=Case("multi-table","Cross-schema moves and swaps, multi-table DROP, name reuse and restart",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n VARCHAR(20)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"),
        .init("INSERT INTO ddlcompat.t VALUES(1,'first')"),
        .init("CREATE TABLE ddlcompat.u(id INT PRIMARY KEY,n INT)"),
        .init("INSERT INTO ddlcompat.u VALUES(2,20)"),
        .init("RENAME TABLE ddlcompat.t TO otherdb.moved",[
            .init("SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='otherdb' AND TABLE_NAME='moved'","utf8mb4_bin"),
            .init("SELECT id,n FROM otherdb.moved","1\tfirst")],restartBefore:true),
        .init("UPDATE otherdb.moved SET n='changed' WHERE id=1",[.init("SELECT id,n FROM otherdb.moved","1\tchanged")]),
        .init("RENAME TABLE otherdb.moved TO ddlcompat.spare,ddlcompat.u TO otherdb.moved,ddlcompat.spare TO ddlcompat.u",[
            .init("SELECT id,n FROM otherdb.moved","2\t20"),.init("SELECT id,n FROM ddlcompat.u","1\tchanged")],restartBefore:true),
        .init("CREATE TABLE otherdb.copy LIKE otherdb.moved"),
        .init("INSERT INTO otherdb.copy VALUES(3,30)",[.init("SELECT id,n FROM otherdb.copy","3\t30")]),
        .init("DROP TABLE ddlcompat.u,otherdb.moved,otherdb.copy RESTRICT",[
            .init("SELECT COUNT(*) FROM information_schema.TABLES WHERE (TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='u') OR (TABLE_SCHEMA='otherdb' AND TABLE_NAME IN ('moved','copy'))","0")],restartBefore:true),
        .init("DROP TABLE IF EXISTS ddlcompat.u,otherdb.moved,otherdb.absent CASCADE",restartBefore:true),
        .init("CREATE TABLE ddlcompat.u(id INT PRIMARY KEY,n DECIMAL(10,2))"),
        .init("INSERT INTO ddlcompat.u VALUES(4,4.25)",[.init("SELECT id,n FROM ddlcompat.u","4\t4.25")],restartBefore:true)
    ])
    static let crossSchemaRelationships=Case("cross-schema-relationships","Cross-schema relationship metadata, cascades and ordered DROP with restart",[
        .init("CREATE TABLE ddlcompat.parent(id INT PRIMARY KEY,n INT)"),
        .init("CREATE TABLE ddlcompat.child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid))",sqlTransactional:"CREATE TABLE ddlcompat.child(id INT PRIMARY KEY,pid INT,KEY by_parent(pid),FOREIGN KEY(pid) REFERENCES ddlcompat.parent(id) ON UPDATE CASCADE ON DELETE CASCADE)"),
        .init("INSERT INTO ddlcompat.parent VALUES(1,10)"),
        .init("INSERT INTO ddlcompat.child VALUES(1,1)"),
        .init("RENAME TABLE ddlcompat.parent TO otherdb.parent",restartBefore:true),
        .init("RENAME TABLE ddlcompat.child TO otherdb.moved_child",[
            .init("SELECT COUNT(*) FROM otherdb.moved_child c JOIN otherdb.parent p ON p.id=c.pid","1")],restartBefore:true),
        .init("UPDATE otherdb.parent SET n=20 WHERE id=1",[
            .init("SELECT COUNT(*) FROM otherdb.moved_child c JOIN otherdb.parent p ON p.id=c.pid","1")],sqlTransactional:"UPDATE otherdb.parent SET id=2 WHERE id=1"),
        .init("RENAME TABLE otherdb.parent TO ddlcompat.parent,otherdb.moved_child TO ddlcompat.child",[
            .init("SELECT COUNT(*) FROM ddlcompat.child c JOIN ddlcompat.parent p ON p.id=c.pid","1")],restartBefore:true),
        .init("DROP TABLE ddlcompat.child,ddlcompat.parent",[
            .init("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat'","0")],restartBefore:true)
    ])
}
