import Foundation

/// Original fixtures, informed by both pinned MySQL trees. Each phase is checked
/// against source/native/target data before the next phase can overwrite evidence.
enum DMLCompatibilityCases {
    struct Phase { let sql: String; let check: String }
    struct Case {
        let id: String
        let definition: String
        let phases: [Phase]
        var setup: String = ""
    }
    static let cases: [Case] = [
        Case(id:"values",definition:"id INT PRIMARY KEY,v INT NOT NULL",phases:[
            .init(sql:"INSERT INTO poc.matrix_values VALUES(1,10),(2,20),(3,30)",check:"SELECT COUNT(*)=3 AND SUM(v)=60 FROM poc.matrix_values"),
            .init(sql:"UPDATE poc.matrix_values SET v=v*2 WHERE id IN (1,2)",check:"SELECT SUM(v)=90 FROM poc.matrix_values"),
            .init(sql:"DELETE FROM poc.matrix_values WHERE id IN (1,3)",check:"SELECT COUNT(*)=1 AND MIN(id)=2 AND MIN(v)=40 FROM poc.matrix_values")]),
        Case(id:"upsert",definition:"id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)",phases:[
            .init(sql:"INSERT INTO poc.matrix_upsert VALUES(1,10),(2,20)",check:"SELECT COUNT(*)=2 FROM poc.matrix_upsert"),
            .init(sql:"INSERT INTO poc.matrix_upsert VALUES(1,11),(3,30) ON DUPLICATE KEY UPDATE v=VALUES(v)",check:"SELECT COUNT(*)=3 AND SUM(v)=61 FROM poc.matrix_upsert"),
            .init(sql:"INSERT INTO poc.matrix_upsert VALUES(1,11) ON DUPLICATE KEY UPDATE v=VALUES(v)",check:"SELECT COUNT(*)=3 AND SUM(v)=61 FROM poc.matrix_upsert")]),
        Case(id:"replace",definition:"id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)",phases:[
            .init(sql:"INSERT INTO poc.matrix_replace VALUES(1,10),(2,20)",check:"SELECT COUNT(*)=2 FROM poc.matrix_replace"),
            .init(sql:"REPLACE INTO poc.matrix_replace VALUES(1,20),(3,30)",check:"SELECT COUNT(*)=2 AND SUM(id)=4 AND SUM(v)=50 FROM poc.matrix_replace")]),
        Case(id:"ignore",definition:"id INT PRIMARY KEY,v INT NOT NULL,UNIQUE KEY uk(v)",phases:[
            .init(sql:"INSERT INTO poc.matrix_ignore VALUES(1,10)",check:"SELECT COUNT(*)=1 FROM poc.matrix_ignore"),
            .init(sql:"INSERT IGNORE INTO poc.matrix_ignore VALUES(1,11),(2,20),(3,10)",check:"SELECT COUNT(*)=2 AND SUM(v)=30 FROM poc.matrix_ignore"),
            .init(sql:"INSERT IGNORE INTO poc.matrix_ignore VALUES(1,99)",check:"SELECT COUNT(*)=2 AND SUM(v)=30 FROM poc.matrix_ignore")]),
        Case(id:"select",definition:"id INT PRIMARY KEY,v INT NOT NULL",phases:[
            .init(sql:"INSERT INTO poc.matrix_select SELECT id+10,v*3 FROM poc.matrix_input",check:"SELECT COUNT(*)=2 AND SUM(v)=90 FROM poc.matrix_select"),
            .init(sql:"UPDATE poc.matrix_select a JOIN poc.matrix_input b ON a.id=b.id+10 SET a.v=b.v+1",check:"SELECT SUM(v)=32 FROM poc.matrix_select"),
            .init(sql:"DELETE a FROM poc.matrix_select a JOIN poc.matrix_input b ON a.id=b.id+10 WHERE b.id=1",check:"SELECT COUNT(*)=1 AND MIN(id)=12 FROM poc.matrix_select")],setup:"CREATE TABLE poc.matrix_input(id INT PRIMARY KEY,v INT NOT NULL); INSERT INTO poc.matrix_input VALUES(1,10),(2,20)"),
        Case(id:"load",definition:"id INT PRIMARY KEY,v INT NOT NULL",phases:[
            .init(sql:"SELECT 1,10 UNION ALL SELECT 2,20 INTO OUTFILE '/var/lib/mysql-files/replicator-dml.tsv'; LOAD DATA INFILE '/var/lib/mysql-files/replicator-dml.tsv' INTO TABLE poc.matrix_load",check:"SELECT COUNT(*)=2 AND SUM(v)=30 FROM poc.matrix_load")]),
        Case(id:"integers",definition:"id TINYINT PRIMARY KEY,a TINYINT,b TINYINT UNSIGNED,c SMALLINT,d SMALLINT UNSIGNED,e MEDIUMINT,f MEDIUMINT UNSIGNED",phases:[
            .init(sql:"INSERT INTO poc.matrix_integers VALUES(-128,-128,255,-32768,65535,-8388608,16777215),(127,127,0,32767,0,8388607,0)",check:"SELECT COUNT(*)=2 AND MIN(e)=-8388608 AND MAX(f)=16777215 FROM poc.matrix_integers"),
            .init(sql:"UPDATE poc.matrix_integers SET id=0,a=NULL,b=1,c=-1,d=1,e=-1,f=1 WHERE id=-128",check:"SELECT COUNT(*)=1 FROM poc.matrix_integers WHERE id=0 AND a IS NULL AND e=-1"),
            .init(sql:"DELETE FROM poc.matrix_integers WHERE id=127",check:"SELECT COUNT(*)=1 FROM poc.matrix_integers")]),
        Case(id:"decimal",definition:"id INT PRIMARY KEY,a DECIMAL(65,30),b DECIMAL(10,2) UNSIGNED,c DECIMAL(4,4)",phases:[
            .init(sql:"INSERT INTO poc.matrix_decimal VALUES(1,-12345678901234567890123456789012345.123456789012345678901234567890,99999999.99,-0.9999),(2,0,0,0)",check:"SELECT COUNT(*)=1 FROM poc.matrix_decimal WHERE a=-12345678901234567890123456789012345.123456789012345678901234567890 AND b=99999999.99 AND c=-0.9999"),
            .init(sql:"UPDATE poc.matrix_decimal SET a=99999999999999999999999999999999999.999999999999999999999999999999,b=NULL,c=0.0001 WHERE id=1",check:"SELECT COUNT(*)=1 FROM poc.matrix_decimal WHERE a=99999999999999999999999999999999999.999999999999999999999999999999 AND b IS NULL AND c=0.0001"),
            .init(sql:"DELETE FROM poc.matrix_decimal WHERE id=2",check:"SELECT COUNT(*)=1 FROM poc.matrix_decimal")]),
        Case(id:"temporal",definition:"id INT PRIMARY KEY,d DATE,dt DATETIME(6),ts TIMESTAMP(6) NULL,t TIME(6),y YEAR",phases:[
            .init(sql:"SET SESSION time_zone='+05:30'; INSERT INTO poc.matrix_temporal VALUES(1,'2024-02-29','9999-12-31 23:59:59.999999','2024-02-29 05:30:00.123456','-838:59:59.000000',2155),(2,'0000-00-00','0000-00-00 00:00:00','0000-00-00 00:00:00','-00:00:00.000001',0)",check:"SELECT COUNT(*)=1 FROM poc.matrix_temporal WHERE id=1 AND ts='2024-02-29 00:00:00.123456' AND t='-838:59:59.000000' AND y=2155"),
            .init(sql:"UPDATE poc.matrix_temporal SET ts='2038-01-19 03:14:07.999999',t='838:59:59.000000',d=NULL,y=1901 WHERE id=1",check:"SELECT COUNT(*)=1 FROM poc.matrix_temporal WHERE id=1 AND ts='2038-01-19 03:14:07.999999' AND d IS NULL AND y=1901"),
            .init(sql:"DELETE FROM poc.matrix_temporal WHERE id=2",check:"SELECT COUNT(*)=1 FROM poc.matrix_temporal")]),
        Case(id:"precision",definition:"id INT PRIMARY KEY,t0 TIME,t1 TIME(1),t2 TIME(2),t3 TIME(3),t4 TIME(4),t5 TIME(5),t6 TIME(6),d0 DATETIME,d3 DATETIME(3),s0 TIMESTAMP NULL,s3 TIMESTAMP(3) NULL",phases:[
            .init(sql:"INSERT INTO poc.matrix_precision VALUES(1,'-12:34:56','-00:00:00.1','-00:00:00.12','-00:00:00.123','-00:00:00.1234','-00:00:00.12345','-00:00:00.123456','2024-01-01 12:34:56','2024-01-01 12:34:56.789','1970-01-01 00:00:01','2024-01-01 12:34:56.789')",check:"SELECT COUNT(*)=1 FROM poc.matrix_precision WHERE t6='-00:00:00.123456' AND d3='2024-01-01 12:34:56.789'"),
            .init(sql:"UPDATE poc.matrix_precision SET t1='12:34:56.1',t6='00:00:00',d3=NULL WHERE id=1",check:"SELECT COUNT(*)=1 FROM poc.matrix_precision WHERE t1='12:34:56.1' AND t6='00:00:00' AND d3 IS NULL")]),
        Case(id:"lob",definition:"id INT PRIMARY KEY,a TINYTEXT,b TEXT,c MEDIUMTEXT,d LONGTEXT,e TINYBLOB,f BLOB,g MEDIUMBLOB,h LONGBLOB,KEY prefix_key(b(10))",phases:[
            .init(sql:"INSERT INTO poc.matrix_lob VALUES(1,CONVERT(0x0027F09F988065CC812020 USING utf8mb4),REPEAT('x',1000),REPEAT('y',70000),'',0x00FF275C,REPEAT(0xFF,1000),REPEAT(0x00FF,35000),NULL)",check:"SELECT COUNT(*)=1 FROM poc.matrix_lob WHERE HEX(a)='0027F09F988065CC812020' AND OCTET_LENGTH(c)=70000 AND OCTET_LENGTH(g)=70000 AND h IS NULL"),
            .init(sql:"UPDATE poc.matrix_lob SET a=NULL,b='',c='short',e=X'',h=0x00FF WHERE id=1",check:"SELECT COUNT(*)=1 FROM poc.matrix_lob WHERE a IS NULL AND b='' AND c='short' AND e=X'' AND HEX(h)='00FF'"),
            .init(sql:"DELETE FROM poc.matrix_lob WHERE id=1",check:"SELECT COUNT(*)=0 FROM poc.matrix_lob")]),
        Case(id:"defaults",definition:"id INT PRIMARY KEY AUTO_INCREMENT,v INT NOT NULL DEFAULT 7,s VARCHAR(40) DEFAULT 'seed',ts TIMESTAMP(6) NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)",phases:[
            .init(sql:"SET timestamp=1700000000.123456; INSERT INTO poc.matrix_defaults(s) VALUES(DEFAULT),('explicit')",check:"SELECT COUNT(*)=2 AND SUM(id)=3 AND SUM(v)=14 FROM poc.matrix_defaults"),
            .init(sql:"SET timestamp=1700000001.654321; UPDATE poc.matrix_defaults SET v=9 WHERE id=1",check:"SELECT COUNT(*)=1 FROM poc.matrix_defaults WHERE id=1 AND v=9 AND ts='2023-11-14 22:13:21.654321'"),
            .init(sql:"INSERT INTO poc.matrix_defaults(id,v,s,ts) VALUES(0,0,'zero',NULL),(20,20,'explicit',NULL)",check:"SELECT COUNT(*)=4 AND MIN(id)=0 AND MAX(id)=20 FROM poc.matrix_defaults")])
    ]

    struct Rejection {
        let id: String
        let sourceDefinition: String
        let targetDefinition: String
        let values: String
        let reason: String
    }
    static let rejections: [Rejection] = [
        .init(id:"mysql84-collation",sourceDefinition:"id INT PRIMARY KEY,v VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci",targetDefinition:"id INT PRIMARY KEY,v VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",values:"(1,'test')",reason:"collation"),
        .init(id:"decimal-scale",sourceDefinition:"id INT PRIMARY KEY,v DECIMAL(10,3)",targetDefinition:"id INT PRIMARY KEY,v DECIMAL(10,2)",values:"(1,1.234)",reason:"precision"),
        .init(id:"decimal-sign",sourceDefinition:"id INT PRIMARY KEY,v DECIMAL(10,2) UNSIGNED",targetDefinition:"id INT PRIMARY KEY,v DECIMAL(10,2)",values:"(1,1.23)",reason:"signedness"),
        .init(id:"time-precision",sourceDefinition:"id INT PRIMARY KEY,v TIME(6)",targetDefinition:"id INT PRIMARY KEY,v TIME(3)",values:"(1,'12:34:56.123456')",reason:"precision"),
        .init(id:"blob-width",sourceDefinition:"id INT PRIMARY KEY,v MEDIUMBLOB",targetDefinition:"id INT PRIMARY KEY,v BLOB",values:"(1,0x00FF)",reason:"type"),
        .init(id:"generated",sourceDefinition:"id INT PRIMARY KEY,v INT",targetDefinition:"id INT PRIMARY KEY,v INT AS (id+1) STORED",values:"(1,2)",reason:"EXTRA"),
        .init(id:"float",sourceDefinition:"id INT PRIMARY KEY,v FLOAT",targetDefinition:"id INT PRIMARY KEY,v FLOAT",values:"(1,1.25)",reason:"column type not supported"),
        .init(id:"json",sourceDefinition:"id INT PRIMARY KEY,v JSON",targetDefinition:"id INT PRIMARY KEY,v JSON",values:"(1,JSON_OBJECT('a',1))",reason:"column type not supported")
    ]

    static func transactionCount(_ set: String) throws -> Int {
        var count=0
        for server in set.split(separator:",") {
            let parts=server.split(separator:":")
            try require(parts.count >= 2,"invalid fixture GTID delta")
            for interval in parts.dropFirst() {
                let bounds=interval.split(separator:"-")
                guard let first=Int(bounds[0]),let last=Int(bounds.last!),first>0,last>=first,last-first<10000 else {throw LabError("invalid fixture GTID interval")}
                count += last-first+1
            }
        }
        return count
    }
}
