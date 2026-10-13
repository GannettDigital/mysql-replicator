import Foundation

extension SharedCorrectness.Run {
    /// Preserve the legacy filter's row/binlog/state oracles on both topologies.
    /// The continuous correctness writer has drained before these isolated states.
    func filters() throws {
        guard selects(DDLCoverageCases.wildcardFilter.id) else { return }
        let original=f.config
        defer { f.config=original }
        let stop=f.profile.nativeVersion.stopReplica
        let start=f.profile.nativeVersion.startReplica
        let patterns=["temp.%","poc.ignore\\_%","scratch_.%"]
        let nativePatterns=patterns.map { "'"+$0.replacingOccurrences(of:"\\",with:"\\\\")+"'" }.joined(separator:",")
        try f.awaitNative()
        _ = try f.sql(.native,stop+"; CHANGE REPLICATION FILTER REPLICATE_WILD_IGNORE_TABLE=(\(nativePatterns))")
        for role in LabProfile.Role.allCases {
            _ = try f.sql(role,"SET sql_log_bin=0; CREATE DATABASE IF NOT EXISTS poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS poc.items; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL) ENGINE=\(f.profile.engine(role)); INSERT INTO poc.items VALUES(1,'updated',1),(3,'final-three',18446744073709551615)")
        }
        func configuration(_ label: String, before: Boundary, count: Int) -> [String:Any] {
            var config=original, source=config["source"] as! [String:Any]
            source["start"]=f.variant.start(before)
            source["stopAfterTransactions"]=count; config["source"]=source
            config["stateDirectory"]="/evidence/"+label
            config["replicateWildIgnoreTable"]=patterns
            return config
        }
        func run(_ test: QualificationCase, config: [String:Any], initialize: Bool = true, reason: String? = nil) throws -> [String:Any] {
            f.config=config; try f.installConfig(test.id)
            let client=try f.startClient(test.id,arguments:["run","--config","/evidence/"+test.id+".yaml"]+(initialize ? ["--initialize"] : []))
            let exit=try f.runner.run(["docker","wait",client],timeout:90).text
            let logs=try f.docker(["logs",client])
            try logs.stdout.write(to:f.output.appendingPathComponent(test.id+".ndjson"))
            try logs.stderr.write(to:f.output.appendingPathComponent(test.id+".diagnostic.json"))
            try require(reason == nil ? exit == "0" : exit != "0","unexpected filter process exit: "+exit)
            guard let line=logs.stderr.split(separator:10).last,
                  let result=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing filter summary") }
            if let reason { try require((result["reason"] as? String ?? "").contains(reason),"wrong included-DDL refusal: \(result)") }
            // Copy only after the writer exits; each restart gets a fresh snapshot.
            _ = try f.docker(["cp",f.helper+":"+(config["stateDirectory"] as! String),f.output.appendingPathComponent("snapshot-"+test.id).path])
            return result
        }
        func state(_ id: String,_ query: String) throws -> String {
            try f.runner.run(["sqlite3",f.output.appendingPathComponent("snapshot-"+id+"/state.sqlite").path,query]).text
        }
        let test=DDLCoverageCases.wildcardFilter, before=try f.boundary()
        let nativeBefore=try f.boundary(.native), targetBefore=try f.boundary(.target)
        let workload = [
            "CREATE DATABASE temp",
            "CREATE TABLE temp.opaque(id INT PRIMARY KEY,d DECIMAL(20,4),j JSON,ts DATETIME) ENGINE=InnoDB",
            "INSERT INTO temp.opaque VALUES(1,123.45,JSON_OBJECT('a',1),NOW())",
            "UPDATE temp.opaque SET d=456.78 WHERE id=1",
            "BEGIN; INSERT INTO temp.opaque VALUES(2,1,NULL,NULL); UPDATE temp.opaque SET d=2 WHERE id=2; COMMIT",
            "ALTER TABLE temp.opaque MODIFY d DECIMAL(25,6)",
            "CREATE INDEX ignored_index ON temp.opaque(d)",
            "RENAME TABLE temp.opaque TO temp.renamed",
            "DELETE FROM temp.renamed WHERE id=1",
            "CREATE TABLE poc.ignore_table(id INT PRIMARY KEY,d DECIMAL(20,4)) ENGINE=InnoDB",
            "INSERT INTO poc.ignore_table VALUES(1,12.34)",
            "CREATE TABLE poc.ignoreXtable(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL)",
            "DROP TABLE poc.ignoreXtable",
            "CREATE DATABASE scratch1",
            "CREATE TABLE scratch1.t(id INT PRIMARY KEY) ENGINE=InnoDB",
            "INSERT INTO scratch1.t VALUES(1)",
            "CREATE TABLE temp.mixed(id INT PRIMARY KEY,n INT)",
            "INSERT INTO temp.mixed VALUES(91,1)",
            "INSERT INTO poc.items VALUES(91,'included',1)",
            "UPDATE poc.items p JOIN temp.mixed t ON p.id=t.id SET p.quantity=2,t.n=2 WHERE p.id=91",
            "DELETE FROM poc.items WHERE id=91",
            "DROP TABLE temp.mixed,temp.renamed",
            "DROP TABLE poc.ignore_table",
            "DROP DATABASE scratch1",
            "DROP DATABASE temp"
        ]
        let config=configuration(test.id,before:before,count:workload.count)
        try reporter.run(test) {
            for sql in workload { _ = try f.sql(.source,sql) }
            _ = try f.sql(.native,start)
            let result=try run(test,config:config), end=try f.boundary()
            try f.awaitNative(); _ = try f.sql(.native,stop)
            try reporter.assertion("filter-effects",evidence:test.id+"-effects.json") {
                try require(result["transactionsApplied"] as? Int == workload.count && result["rowsApplied"] as? Int == 3 && result["ddlApplied"] as? Int == 2 && result["appliedGTIDSet"] as? String == end.gtids,"filtered checkpoint/counters differ")
                for role: LabProfile.Role in [.native,.target] {
                    try require(f.h.rows(f.profile.service(role)) == Fixture.final,"filtered workload changed retained rows")
                    try require(f.sql(role,"SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN ('temp','scratch1')") == "0","excluded schema reached replica")
                    try require(f.sql(role,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='ignore_table'") == "0","escaped wildcard did not exclude table")
                }
                return ["patterns":patterns,"workload":workload,"summary":result,"source_before":before.json,"source_after":end.json,"reference_decoder":referenceDecoderVersion,"native_status":try f.h.sql("native",f.profile.nativeVersion.replicaStatus+"\\G",headers:true)]
            }
            try reporter.assertion("normalized-binlog",evidence:test.id+"-binlogs.json") {
                let expected=[RowOperation("insert",after:["91","included","1"]),RowOperation("update",before:["91","included","1"],after:["91","included","2"]),RowOperation("delete",before:["91","included","2"])]
                var observed:[String:Any]=[:]
                for (role,begin) in [(LabProfile.Role.native,nativeBefore),(.target,targetBefore)] {
                    let service=f.profile.service(role)
                    let operations=try f.h.capture(service,start:begin,end:f.boundary(role))
                    try Comparison.operations(operations,expected:expected)
                    observed[role.rawValue]=try jsonObject(operations)
                }
                return observed
            }
        }
        if selects(DDLCoverageCases.wildcardResume.id) {
            let resumedTest=DDLCoverageCases.wildcardResume
            try reporter.run(resumedTest) {
                var resumed=config, source=resumed["source"] as! [String:Any]
                source["stopAfterTransactions"]=1; resumed["source"]=source
                _ = try f.sql(.source,"UPDATE poc.items SET value='after-filter-resume' WHERE id=1")
                let result=try run(resumedTest,config:resumed,initialize:false)
                _ = try f.sql(.native,start); try f.awaitNative(); _ = try f.sql(.native,stop)
                try reporter.assertion("saved-filter-state",evidence:resumedTest.id+"-state.json") {
                    let saved=try state(resumedTest.id,"SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||ddl_applied FROM state; SELECT COUNT(*) FROM row_intents; SELECT COUNT(*) FROM ddl_intents; SELECT COUNT(*) FROM schemas")
                    try require(saved == "STOPPED|\(workload.count+1)|4|2\n4\n2\n2","excluded work created intents/schemas or resume replayed progress: "+saved)
                    try require(result["transactionsApplied"] as? Int == workload.count+1 && result["rowsApplied"] as? Int == 4 && result["appliedGTIDSet"] as? String == f.boundary().gtids,"filtered resume counters/checkpoint differ")
                    for role in LabProfile.Role.allCases { try require(f.sql(role,"SELECT value FROM poc.items WHERE id=1") == "after-filter-resume","resume data differs") }
                    return ["state":saved,"summary":result]
                }
            }
        }
        // As in native replication, filters must not waive errors on included DDL.
        _ = try f.sql(.native,"CHANGE REPLICATION FILTER REPLICATE_WILD_IGNORE_TABLE=(); "+start)
        if selects(DDLCoverageCases.wildcardRejection.id) {
            let rejected=DDLCoverageCases.wildcardRejection
            try reporter.run(rejected) {
                let before=try f.boundary(), config=configuration(rejected.id,before:before,count:2)
                _ = try f.sql(.source,"CREATE TABLE poc.filter_included(id INT PRIMARY KEY,d JSON); INSERT INTO poc.items VALUES(92,'must-not-apply',1)")
                let result=try run(rejected,config:config,reason:"unsupported DDL column type")
                try f.awaitNative()
                try reporter.assertion("included-refusal",evidence:rejected.id+"-state.json") {
                    let saved=try state(rejected.id,"SELECT lifecycle||'|'||transactions_applied FROM state; SELECT COUNT(*) FROM ddl_intents")
                    try require(saved == "BLOCKED|0\n0","included DDL bypassed fail-stop policy")
                    try require((result["progress"] as? [String:Any])?["appliedGTIDSet"] as? String == before.gtids,"included rejection advanced GTIDs")
                    try require(f.sql(.target,"SELECT COUNT(*) FROM poc.items WHERE id=92") == "0","following row escaped refusal")
                    try require(f.sql(.native,"SELECT COUNT(*) FROM poc.items WHERE id=92") == "1","native reference did not apply included workload")
                    return ["state":saved,"diagnostic":result,"source_before":before.json]
                }
            }
        }
    }
}
