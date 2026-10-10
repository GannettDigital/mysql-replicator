import Foundation

/// Independently authored cases from pinned alter_table.test (MODIFY and WL#6555).
/// Every case has a metadata oracle; row probes target the behavior that changed.
enum ModifyIndexCases {
    struct Step { let sql:String; let rows:String; var affectedRows:Int = 1 }
    struct Case {
        let test:QualificationCase
        let native:QualificationCase
        let seed,sql,table,columns,indexes:String
        let workload:[Step]
        let retained:String
        init(_ id:String,_ name:String,seed:String,sql:String,table:String,columns:String,indexes:String,retained:String,workload:[Step],file:String=#filePath,line:UInt=#line) {
            test=QualificationCase("ddl-"+id,name,file:file,line:line)
            native=QualificationCase("native-"+id,name,file:file,line:line)
            self.seed=seed;self.sql=sql;self.table=table;self.columns=columns;self.indexes=indexes;self.retained=retained;self.workload=workload
        }
    }
    static let cases:[Case]=[
        .init("modify-demo-varchar-120","ALTER TABLE demo.explicit_default_engine MODIFY COLUMN name VARCHAR(120); verify metadata and following INSERT/UPDATE/DELETE",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.explicit_default_engine; CREATE TABLE demo.explicit_default_engine(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.explicit_default_engine VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.explicit_default_engine MODIFY COLUMN name VARCHAR(120)",table:"explicit_default_engine",
            columns:"id:int:NO:::<NULL>\nname:varchar(120):YES:utf8mb4:utf8mb4_unicode_ci:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.explicit_default_engine(id,name,n,b) VALUES(2,CONVERT(0x78787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t78787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878\t8\tCAFE"),
                Step(sql:"UPDATE demo.explicit_default_engine SET id=3,name='changed',n=9,b=NULL WHERE id=2",rows:"1\t73656564\t7\t00FF\n3\t6368616E676564\t9\tNULL"),
                Step(sql:"DELETE FROM demo.explicit_default_engine WHERE id=3",rows:"1\t73656564\t7\t00FF")]),
        .init("modify-narrow-text","ALTER TABLE demo.mi MODIFY name VARCHAR(20) NOT NULL COLLATE utf8mb4_bin; verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY name VARCHAR(20) NOT NULL COLLATE utf8mb4_bin",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(20):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0xC3A90020 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\tC3A90020\t8\tCAFE")]),
        .init("modify-binary-width","ALTER TABLE demo.mi MODIFY b VARBINARY(32); verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY b VARBINARY(32)",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(32):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0x00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\t00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF")]),
        .init("modify-binary-narrow","ALTER TABLE demo.mi MODIFY b VARBINARY(4); verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY b VARBINARY(4)",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(4):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE")]),
        .init("modify-integer-signed","ALTER TABLE demo.mi MODIFY n BIGINT; verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY n BIGINT",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:bigint:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),4294967296,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t4294967296\tCAFE")]),
        .init("modify-primary-widen","ALTER TABLE demo.mi MODIFY id BIGINT UNSIGNED; verify metadata and following INSERT/UPDATE/DELETE",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY id BIGINT UNSIGNED",table:"mi",
            columns:"id:bigint unsigned:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(4294967296,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n4294967296\t6E657874\t8\tCAFE"),
                Step(sql:"UPDATE demo.mi SET id=4294967297,name='changed',n=9,b=NULL WHERE id=4294967296",rows:"1\t73656564\t7\t00FF\n4294967297\t6368616E676564\t9\tNULL"),
                Step(sql:"DELETE FROM demo.mi WHERE id=4294967297",rows:"1\t73656564\t7\t00FF")]),
        .init("modify-integer-narrow","ALTER TABLE demo.mi MODIFY id INT NOT NULL; verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id bigint NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY id INT NOT NULL",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE")]),
        .init("modify-not-null","ALTER TABLE demo.mi MODIFY name VARCHAR(40) NOT NULL COLLATE utf8mb4_bin; verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY name VARCHAR(40) NOT NULL COLLATE utf8mb4_bin",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE")]),
        .init("modify-first","ALTER TABLE demo.mi MODIFY name VARCHAR(120) FIRST; verify metadata and following INSERT/UPDATE/DELETE",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY name VARCHAR(120) FIRST",table:"mi",
            columns:"name:varchar(120):YES:utf8mb4:utf8mb4_unicode_ci:<NULL>\nid:int:NO:::<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE"),
                Step(sql:"UPDATE demo.mi SET id=3,name='changed',n=9,b=NULL WHERE id=2",rows:"1\t73656564\t7\t00FF\n3\t6368616E676564\t9\tNULL"),
                Step(sql:"DELETE FROM demo.mi WHERE id=3",rows:"1\t73656564\t7\t00FF")]),
        .init("modify-after","ALTER TABLE demo.mi MODIFY n BIGINT AFTER b; verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi MODIFY n BIGINT AFTER b",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nb:varbinary(8):YES:::<NULL>\nn:bigint:YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE")]),
        .init("index-create","CREATE INDEX ix USING BTREE ON demo.mi(name ASC); verify metadata and following INSERT/UPDATE/DELETE",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"CREATE INDEX ix USING BTREE ON demo.mi(name ASC)",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:1:1:name:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE"),
                Step(sql:"UPDATE demo.mi SET id=3,name='changed',n=9,b=NULL WHERE id=2",rows:"1\t73656564\t7\t00FF\n3\t6368616E676564\t9\tNULL"),
                Step(sql:"DELETE FROM demo.mi WHERE id=3",rows:"1\t73656564\t7\t00FF")]),
        .init("index-unique","CREATE UNIQUE INDEX ix ON demo.mi(name,n); verify metadata and targeted INSERT/UPDATE",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"CREATE UNIQUE INDEX ix ON demo.mi(name,n)",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:0:1:name:FULL:BTREE:A\nix:0:2:n:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE"),
                Step(sql:"UPDATE demo.mi SET id=3,name='changed',n=9,b=NULL WHERE id=2",rows:"1\t73656564\t7\t00FF\n3\t6368616E676564\t9\tNULL")]),
        .init("index-prefix","ALTER TABLE demo.mi ADD KEY ix(name(8),b(2)) USING BTREE; verify metadata and targeted INSERT/UPDATE",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); ",
            sql:"ALTER TABLE demo.mi ADD KEY ix(name(8),b(2)) USING BTREE",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:1:1:name:8:BTREE:A\nix:1:2:b:2:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE"),
                Step(sql:"UPDATE demo.mi SET id=3,name='changed',n=9,b=NULL WHERE id=2",rows:"1\t73656564\t7\t00FF\n3\t6368616E676564\t9\tNULL")]),
        .init("index-rename","ALTER TABLE demo.mi RENAME KEY ix TO renamed; verify metadata and retained rows",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); CREATE INDEX ix ON demo.mi(name(8))",
            sql:"ALTER TABLE demo.mi RENAME KEY ix TO renamed",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nrenamed:1:1:name:8:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[]),
        .init("index-drop","DROP INDEX ix ON demo.mi; verify metadata and retained rows",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); CREATE INDEX ix ON demo.mi(name(8))",
            sql:"DROP INDEX ix ON demo.mi",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[]),
        .init("index-drop-alter","ALTER TABLE demo.mi DROP KEY ix; verify metadata and retained rows",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); CREATE INDEX ix ON demo.mi(name(8))",
            sql:"ALTER TABLE demo.mi DROP KEY ix",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[]),
        .init("index-replace","ALTER TABLE demo.mi DROP INDEX ix, ADD UNIQUE INDEX ix(n,name(4)); verify metadata and targeted INSERT/UPDATE",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); CREATE INDEX ix ON demo.mi(name(8))",
            sql:"ALTER TABLE demo.mi DROP INDEX ix, ADD UNIQUE INDEX ix(n,name(4))",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:0:1:n:FULL:BTREE:A\nix:0:2:name:4:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE"),
                Step(sql:"UPDATE demo.mi SET id=3,name='changed',n=9,b=NULL WHERE id=2",rows:"1\t73656564\t7\t00FF\n3\t6368616E676564\t9\tNULL")]),
        .init("modify-indexed","ALTER TABLE demo.mi MODIFY name VARCHAR(120); verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); CREATE INDEX ix ON demo.mi(name(8))",
            sql:"ALTER TABLE demo.mi MODIFY name VARCHAR(120)",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(120):YES:utf8mb4:utf8mb4_unicode_ci:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:1:1:name:8:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE")]),
        .init("index-like","CREATE TABLE demo.mi_clone LIKE demo.mi; verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); CREATE INDEX ix ON demo.mi(name(8))",
            sql:"CREATE TABLE demo.mi_clone LIKE demo.mi",table:"mi_clone",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:1:1:name:8:BTREE:A",retained:"",workload:[
                Step(sql:"INSERT INTO demo.mi_clone(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"2\t6E657874\t8\tCAFE")]),
        .init("index-table-rename","RENAME TABLE demo.mi TO demo.mi_renamed; verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); CREATE INDEX ix ON demo.mi(name(8))",
            sql:"RENAME TABLE demo.mi TO demo.mi_renamed",table:"mi_renamed",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:1:1:name:8:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi_renamed(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"1\t73656564\t7\t00FF\n2\t6E657874\t8\tCAFE")]),
        .init("index-truncate","TRUNCATE TABLE demo.mi; verify metadata and one following INSERT",
            seed:"SET SESSION sql_log_bin=0; CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS demo.mi_clone,demo.mi_renamed,demo.mi; CREATE TABLE demo.mi(id int NOT NULL PRIMARY KEY,name varchar(40) COLLATE utf8mb4_bin NOT NULL,n int unsigned NULL,b varbinary(8) NULL) DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci; INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF); CREATE INDEX ix ON demo.mi(name(8))",
            sql:"TRUNCATE TABLE demo.mi",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):NO:utf8mb4:utf8mb4_bin:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:1:1:name:8:BTREE:A",retained:"",workload:[
                Step(sql:"INSERT INTO demo.mi(id,name,n,b) VALUES(2,CONVERT(0x6E657874 USING utf8mb4),8,0xCAFE)",rows:"2\t6E657874\t8\tCAFE")]),
        .init("index-unique-null","Unique text-prefix index accepts distinct NULL rows and constrains following updates",seed:"SET SESSION sql_log_bin=0; DROP TABLE IF EXISTS demo.mi; CREATE TABLE demo.mi(id INT PRIMARY KEY,name VARCHAR(40) COLLATE utf8mb4_unicode_ci NULL,n INT UNSIGNED,b VARBINARY(8)); INSERT INTO demo.mi VALUES(1,'seed',7,0x00FF)",sql:"ALTER TABLE demo.mi ADD UNIQUE INDEX ix(name(8))",table:"mi",
            columns:"id:int:NO:::<NULL>\nname:varchar(40):YES:utf8mb4:utf8mb4_unicode_ci:<NULL>\nn:int unsigned:YES:::<NULL>\nb:varbinary(8):YES:::<NULL>",
            indexes:"PRIMARY:0:1:id:FULL:BTREE:A\nix:0:1:name:8:BTREE:A",retained:"1\t73656564\t7\t00FF",workload:[
                Step(sql:"INSERT INTO demo.mi VALUES(2,NULL,8,NULL),(3,NULL,9,0x00FF)",rows:"1\t73656564\t7\t00FF\n2\tNULL\t8\tNULL\n3\tNULL\t9\t00FF",affectedRows:2),
                Step(sql:"UPDATE demo.mi SET id=4,name='other' WHERE id=2",rows:"1\t73656564\t7\t00FF\n3\tNULL\t9\t00FF\n4\t6F74686572\t8\tNULL"),
                Step(sql:"DELETE FROM demo.mi WHERE id IN (3,4)",rows:"1\t73656564\t7\t00FF",affectedRows:2)]),
    ]
    struct Failure {
        let test:QualificationCase
        let sql:String
        let width:Int
        let duplicate:Bool
        let error:String
        init(_ id:String,_ name:String,_ sql:String,width:Int=40,duplicate:Bool=false,error:String,file:String=#filePath,line:UInt=#line) {
            test=QualificationCase(id,name,file:file,line:line);self.sql=sql;self.width=width;self.duplicate=duplicate;self.error=error
        }
    }
    static let failures:[Failure]=[
        Failure("ddl-index-byte-limit","Source accepts a unique key larger than MyISAM permits; both replicas stop before the next row","CREATE UNIQUE INDEX oversized ON demo.mi(name)",width:300,error:"1071"),
        Failure("ddl-index-duplicate-target","Replica-only duplicate values reject UNIQUE creation and retain the pending intent","CREATE UNIQUE INDEX unique_name ON demo.mi(name)",duplicate:true,error:"1062")
    ]
    static let resume=QualificationCase("ddl-index-resume","Reopen indexed state, apply the next row once, and refuse external index drift before capture")
    static let timeout=QualificationCase("ddl-index-timeout","DDL deadline expires while waiting for a table lock; preserve uncertain intent and refuse skip")
    static let sourceRejected=QualificationCase("native-modify-index-source-rejections","Unsafe narrowing/null conversion, prefix/collation duplicates and invalid index definitions fail at source without a binlog event")
    static func observeRejections(_ h:NativeHarness,reporter:QualificationReporter) throws {
        try reporter.run(sourceRejected) {
            let seed=cases[0].seed.replacingOccurrences(of:"explicit_default_engine",with:"mi").replacingOccurrences(of:"utf8mb4_bin",with:"utf8mb4_unicode_ci")
            _ = try h.sql("native","STOP REPLICA")
            for service in h.services {_ = try h.sql(service,seed+"; CREATE INDEX ix ON demo.mi(name); INSERT INTO demo.mi VALUES(2,'SEED-two',NULL,NULL)")}
            let before=try h.boundary("source")
            var observations:[[String:Any]]=[]
            for sql in ["ALTER TABLE demo.mi MODIFY name VARCHAR(2) NOT NULL","ALTER TABLE demo.mi MODIFY b VARBINARY(8) NOT NULL","CREATE UNIQUE INDEX prefix_conflict ON demo.mi(name(4))","CREATE INDEX bad ON demo.mi(name(100))","DROP INDEX absent ON demo.mi","CREATE INDEX ix ON demo.mi(n)"] {
                var record:[String:Any]=["sql":sql]
                for service in ["source","target57"] {
                    let result=try h.compose(["exec","-T","-e","MYSQL_PWD=fixture-root-only",service,"mysql","--no-defaults","-uroot","-e",sql],checked:false)
                    let diagnostic=String(decoding:result.stderr,as:UTF8.self)
                    try require(result.status != 0 && diagnostic.contains("ERROR "),"invalid DDL unexpectedly succeeded")
                    record[service]=diagnostic
                }
                let after=try h.boundary("source")
                try require(before.file==after.file && before.position==after.position && before.gtids==after.gtids,"source rejection entered binlog")
                observations.append(record)
            }
            try writeJSON(observations,to:h.output.appendingPathComponent("modify-index-source-rejections.json"))
            _ = try h.sql("native","START REPLICA")
        }
    }
    static func metadata(_ h:NativeHarness,_ service:String,_ test:Case,expectedEngine:String? = nil) throws -> [String:String] {
        let condition="TABLE_SCHEMA='demo' AND TABLE_NAME='\(test.table)'"
        let columns=try h.sql(service,"SELECT CONCAT(COLUMN_NAME,':',IF(DATA_TYPE IN ('int','bigint'),CONCAT(DATA_TYPE,IF(COLUMN_TYPE LIKE '%unsigned%',' unsigned','')),COLUMN_TYPE),':',IS_NULLABLE,':',IFNULL(CHARACTER_SET_NAME,''),':',IFNULL(COLLATION_NAME,''),':',IFNULL(COLUMN_DEFAULT,'<NULL>')) FROM information_schema.COLUMNS WHERE \(condition) ORDER BY ORDINAL_POSITION")
        let indexes=try h.sql(service,"SELECT CONCAT(INDEX_NAME,':',NON_UNIQUE,':',SEQ_IN_INDEX,':',COLUMN_NAME,':',IFNULL(CAST(SUB_PART AS CHAR),'FULL'),':',INDEX_TYPE,':',COLLATION) FROM information_schema.STATISTICS WHERE \(condition) ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX")
        let engine=try h.sql(service,"SELECT ENGINE FROM information_schema.TABLES WHERE \(condition)")
        try require(columns==test.columns,"\(test.test.id) \(service) columns differ: \(columns)")
        try require(indexes==test.indexes,"\(test.test.id) \(service) indexes differ: \(indexes)")
        try require(engine==(expectedEngine ?? (service=="source" ? "InnoDB" : "MyISAM")),"index DDL changed local engine")
        return ["columns":columns,"indexes":indexes,"engine":engine]
    }
    static func rows(_ h:NativeHarness,_ service:String,_ table:String) throws -> String {
        try h.sql(service,"SELECT id,IFNULL(HEX(name),'NULL'),IFNULL(CAST(n AS CHAR),'NULL'),IFNULL(HEX(b),'NULL') FROM demo.\(table) ORDER BY id",preserveWhitespace:true)
    }
    static func waitNative(_ h:NativeHarness,_ end:Boundary) throws {
        let wait=try h.sql("native","SELECT \(h.serverVersions["native"]!.positionWait)('\(end.file)',\(end.position),20)")
        try require(wait != "NULL" && wait != "-1" && h.status()["Last_SQL_Errno"]=="0","native MODIFY/index did not converge")
    }
    static func observeNative(_ h:NativeHarness,reporter:QualificationReporter) throws {
        for test in cases {
            try reporter.run(test.native) {
                _ = try h.sql("native","STOP REPLICA")
                for service in h.services {_ = try h.sql(service,test.seed)}
                _ = try h.sql("native","START REPLICA")
                for service in ["source","target57"] {
                    let warnings=try h.sql(service,test.sql+"; SHOW WARNINGS")
                    try require(warnings.isEmpty,"unexpected MODIFY/index warnings: \(warnings)")
                }
                try waitNative(h,h.boundary("source"))
                for service in h.services {_ = try metadata(h,service,test);try require(rows(h,service,test.table)==test.retained,"native DDL changed retained rows")}
                for step in test.workload {
                    for service in ["source","target57"] {_ = try h.sql(service,step.sql)}
                    try waitNative(h,h.boundary("source"))
                    for service in h.services {try require(rows(h,service,test.table)==step.rows,"native following DML differs")}
                }
            }
        }
    }
}
