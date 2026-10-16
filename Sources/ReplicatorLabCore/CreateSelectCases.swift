import Foundation

extension DDLCompatibilityCases {
    static let temporaryCreateSelect=Case("temporary-create-select","Temporary CTAS logs permanent row effects; restart and offline replay preserve them",[
        .init("CREATE TABLE ddlcompat.t(id INT PRIMARY KEY,n INT)"),
        .init("INSERT INTO ddlcompat.t VALUES(1,10),(2,20)"),
        .init("USE ddlcompat; CREATE TEMPORARY TABLE tmp (PRIMARY KEY(id)) SELECT * FROM t; UPDATE tmp SET n=n+1; INSERT INTO t SELECT id+10,n FROM tmp; DROP TEMPORARY TABLE tmp",[
            .init("SELECT * FROM ddlcompat.t ORDER BY id","1\t10\n2\t20\n11\t11\n12\t21"),
            .init("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_NAME='tmp'","0")]),
        .init("USE ddlcompat; CREATE TEMPORARY TABLE tmp SELECT * FROM t WHERE 0; INSERT INTO tmp VALUES(99,99); UPDATE t JOIN tmp ON t.id=tmp.id-98 SET t.n=tmp.n; DROP TEMPORARY TABLE tmp",[
            .init("SELECT * FROM ddlcompat.t ORDER BY id","1\t99\n2\t20\n11\t11\n12\t21")],restartBefore:true),
        .init("DELETE FROM ddlcompat.t WHERE id=2",[.init("SELECT * FROM ddlcompat.t ORDER BY id","1\t99\n11\t11\n12\t21")])
    ])
}

extension SharedCorrectness.Run {
    func createSelectContract() throws {
        guard selects("create-select-contract") else {return}
        try reporter.run(.init("create-select-contract","Native permanent CTAS restrictions and unchanged target progress")) {
            try resetNativeEngine();try f.awaitNative()
            let seed="SET sql_log_bin=0; DROP DATABASE IF EXISTS ctas_contract; CREATE DATABASE ctas_contract CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE ctas_contract.seed(id INT PRIMARY KEY,n INT); INSERT INTO ctas_contract.seed VALUES(1,10)"
            for role in LabProfile.Role.allCases { _ = try f.sql(role,seed) }
            let isolated=LabIsolatedApply(f),start=try f.boundary()
            func attempt(_ role:LabProfile.Role,_ sql:String,_ label:String,_ code:String) throws {
                let result=try f.h.compose(["exec","-T","-e","MYSQL_PWD=fixture-root-only",f.profile.service(role),"mysql","--no-defaults","-uroot","-e",f.profile.session(role)+sql],checked:false)
                try (result.stdout+result.stderr).write(to:f.output.appendingPathComponent(label+".txt"))
                try require(result.status != 0 && String(decoding:result.stderr,as:UTF8.self).contains("ERROR "+code+" "),"unexpected native CTAS result: "+label)
            }
            let create="CREATE TABLE ctas_contract.copied (PRIMARY KEY(id)) SELECT * FROM ctas_contract.seed"
            if f.profile.sourceVersion == .mysql57 {
                try attempt(.source,create,"ctas-source-rejection","1786")
                try require(f.boundary().gtids == start.gtids,"rejected CTAS advanced source GTIDs")
                for role in LabProfile.Role.allCases {
                    try require(f.sql(role,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ctas_contract' AND TABLE_NAME='copied'") == "0","rejected CTAS created a table")
                }
                _ = try f.sql(.source,session+"INSERT INTO ctas_contract.seed VALUES(2,20)")
                try f.awaitNative()
                let config=isolated.configuration("ctas-source-rejection",at:start,count:1)
                let client=try isolated.start("ctas-source-rejection",config:config)
                _ = try isolated.finish(client,label:"ctas-source-rejection",config:config)
                try require(f.sql(.target,"SELECT * FROM ctas_contract.seed ORDER BY id") == f.sql(.native,"SELECT * FROM ctas_contract.seed ORDER BY id"),"following CTAS rejection row differs")
                return
            }
            // Default-engine CTAS emits START TRANSACTION without an ENGINE
            // clause. The native SQL thread uses its MyISAM default and rejects
            // the atomic-DDL clause. Do not rewrite it into non-atomic writes.
            try attempt(.source,"CREATE TABLE ctas_contract.nonatomic ENGINE=MyISAM SELECT * FROM ctas_contract.seed","ctas-source-myisam","1786")
            try attempt(.target,"CREATE TABLE ctas_contract.syntax_probe(id INT PRIMARY KEY) START TRANSACTION","ctas-target-syntax","1064")
            _ = try f.sql(.source,session+create+"; INSERT INTO ctas_contract.seed VALUES(2,20)")
            let events=try f.sql(.source,"SHOW BINLOG EVENTS IN '\(start.file)' FROM \(start.position)")
            try events.write(to:f.output.appendingPathComponent("ctas-source-events.tsv"),atomically:true,encoding:.utf8)
            try require(events.contains("START TRANSACTION") && events.contains("Table_map") && events.contains("Write_rows") && events.contains("Xid"),"atomic CTAS event sequence changed")
            let deadline=Date().addingTimeInterval(30)
            while try f.h.status()["Last_SQL_Errno"] == "0" && Date()<deadline {Thread.sleep(forTimeInterval:0.1)}
            let status=try f.h.status()
            try writeJSON(status,to:f.output.appendingPathComponent("ctas-native-rejection.json"))
            try require(status["Last_SQL_Errno"] == "3979" && status[f.profile.nativeVersion.sqlRunningField] == "No","native MyISAM accepted atomic CTAS")
            let config=isolated.configuration("ctas-atomic",at:start,count:2)
            for initialize in [true,false] {
                let label=initialize ? "ctas-atomic" : "ctas-atomic-resume"
                let client=try isolated.start(label,config:config,initialize:initialize)
                _ = try isolated.finish(client,label:label,config:config,reason:initialize ? "query inside row transaction" : "saved state must be cleanly STOPPED")
                try require(isolated.state(label,"SELECT gtids FROM snapshots ORDER BY id DESC LIMIT 1") == start.gtids,"CTAS failure advanced the checkpoint")
                try require(isolated.state(label,"SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|0","CTAS failure did not retain blocked state")
                try require(isolated.state(label,"SELECT COUNT(*) FROM ddl_intents; SELECT COUNT(*) FROM row_intents") == "0\n0","incomplete CTAS reached the write journal")
            }
            for role:LabProfile.Role in [.native,.target] {
                try require(f.sql(role,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ctas_contract' AND TABLE_NAME='copied'") == "0","atomic CTAS created a replica table")
                try require(f.sql(role,"SELECT * FROM ctas_contract.seed") == "1\t10","following write passed failed CTAS")
            }
            try reseedNativeAfterRejections("ctas-atomic")
        }
    }
}
