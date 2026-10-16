import Foundation

extension DDLCompatibilityCases {
    static let foreignKeyCrossDatabase = Case("foreign-key-cross-database","Cross-database child and parent DROP, surviving schemas, restart and replay",[
        .init("CREATE TABLE ddlcompat.p(id INT PRIMARY KEY) ENGINE=InnoDB"),
        .init("CREATE DATABASE ddlfk CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
        .init("CREATE TABLE ddlfk.c(id INT PRIMARY KEY,pid INT,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES ddlcompat.p(id) ON DELETE CASCADE) ENGINE=InnoDB"),
        .init("INSERT INTO ddlcompat.p VALUES(1)"),
        .init("INSERT INTO ddlfk.c VALUES(1,1)"),
        .init("SET foreign_key_checks=0; DROP DATABASE ddlcompat",[
            .init("SELECT REFERENCED_TABLE_SCHEMA,REFERENCED_TABLE_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='ddlfk' AND REFERENCED_TABLE_NAME IS NOT NULL","ddlcompat\tp")]),
        .init("SET foreign_key_checks=0; INSERT INTO ddlfk.c VALUES(2,2)",[.init("SELECT id,pid FROM ddlfk.c ORDER BY id","1\t1\n2\t2")],restartBefore:true),
        .init("CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
        .init("CREATE TABLE ddlcompat.p(id INT PRIMARY KEY) ENGINE=InnoDB"),
        .init("INSERT INTO ddlcompat.p VALUES(1),(2)"),
        .init("DELETE FROM ddlcompat.p WHERE id=1",[.init("SELECT id,pid FROM ddlfk.c","2\t2")],restartBefore:true),
        .init("DROP DATABASE ddlfk",[.init("SELECT COUNT(*) FROM information_schema.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_SCHEMA='ddlcompat'","0")]),
        .init("DELETE FROM ddlcompat.p WHERE id=2",[.init("SELECT COUNT(*) FROM ddlcompat.p","0")],restartBefore:true),
        .init("CREATE DATABASE ddlfk CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"),
        .init("CREATE TABLE ddlfk.c(id INT PRIMARY KEY,pid INT,CONSTRAINT cf FOREIGN KEY(pid) REFERENCES ddlcompat.p(id)) ENGINE=InnoDB"),
        .init("DROP DATABASE ddlfk"),
        .init("INSERT INTO ddlcompat.p VALUES(3)",[.init("SELECT id FROM ddlcompat.p","3")],restartBefore:true)
    ],nativeInnoDB:true,profileExclusions:[.forward:"Foreign keys require an InnoDB target.",.mysql57MyISAM:"Foreign keys require an InnoDB target."])
}
