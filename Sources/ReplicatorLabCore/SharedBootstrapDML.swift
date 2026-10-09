import Foundation

extension SharedCorrectness.Run {
    func basicDML() throws {
        guard selects(DDLCoverageCases.positive.id) else { return }
        try resetNativeEngine(); try f.awaitNative()
        let isolated=LabIsolatedApply(f)
        for role in LabProfile.Role.allCases {
            _ = try f.sql(role,"SET sql_log_bin=0; CREATE DATABASE IF NOT EXISTS poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; DROP TABLE IF EXISTS poc.items; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL) ENGINE=\(f.profile.engine(role)); INSERT INTO poc.items VALUES(1,'seed-one',1),(2,'seed-two',2)")
        }
        try reporter.run(DDLCoverageCases.positive) {
            var starts: [LabProfile.Role:Boundary] = [:]
            for role in LabProfile.Role.allCases { starts[role]=try f.boundary(role) }
            var config=isolated.configuration("positive",at:starts[.source]!,count:4)
            for (endpoint,password) in [("source","fixture-capture-only"),("target","fixture-apply-only")] {
                var connection=config[endpoint] as! [String:Any]
                connection.removeValue(forKey:"passwordEnvironment"); connection["password"]=password
                config[endpoint]=connection
            }
            let client=try isolated.start("positive",config:config)
            _ = try f.sql(.source,Fixture.sql(transaction:false))
            let end=try f.boundary(), result=try isolated.finish(client,label:"positive",config:config)
            try f.awaitNative()
            try require(result["transactionsApplied"] as? Int == 4 && result["rowsApplied"] as? Int == 4,"basic counters differ")
            for role in LabProfile.Role.allCases {
                try require(f.h.rows(f.profile.service(role)) == Fixture.final,"basic DML rows differ")
                try Comparison.operations(f.h.capture(f.profile.service(role),start:starts[role]!,end:f.boundary(role)),expected:Fixture.operations)
                let directory=f.output.appendingPathComponent(f.profile.service(role))
                try FileManager.default.copyItem(at:directory.appendingPathComponent("operations.json"),to:directory.appendingPathComponent("positive-operations.json"))
            }
            if f.profile == .forward {
                try require(f.sql(.target,"SELECT @@GLOBAL.gtid_executed").isEmpty,"applier injected source GTIDs into target")
                let reads=(result["stageTimings"] as? [String:[String:Any]])?["target.read"]?["count"] as? Int
                try require(reads == 3,"basic DML repeated existence reads")
            }
            let saved=try isolated.state("positive","SELECT lifecycle||'|'||transactions_applied||'|'||rows_applied||'|'||applied_position||'|'||(SELECT gtids FROM snapshots ORDER BY id DESC LIMIT 1) FROM state")
            try require(saved == "STOPPED|4|4|\(end.position)|\(end.gtids)","basic durable boundary differs")
            try require(isolated.state("positive","SELECT COUNT(*) FROM row_intents WHERE status='DONE'") == "4","basic row intents missing")
            try require(isolated.state("positive","SELECT target_uuid FROM state") == f.sql(.target,"SELECT @@server_uuid"),"target identity not persisted")
            try writeJSON(result,to:f.output.appendingPathComponent("positive-summary.json"))
        }
    }

    func bootstrapDML() throws {
        let chosen=DMLCompatibilityCases.cases.filter { selects("bootstrap-matrix-"+$0.id) }
        guard !chosen.isEmpty else { return }
        try resetNativeEngine(); try f.awaitNative()
        let isolated=LabIsolatedApply(f)
        // Replicated-CREATE cases may have left helper tables such as
        // matrix_input. Bootstrap experiments start from their own snapshots.
        for role in LabProfile.Role.allCases { _ = try f.sql(role,"SET sql_log_bin=0; DROP DATABASE IF EXISTS poc; CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci") }
        for test in chosen {
            let id="bootstrap-matrix-"+test.id, table="poc.matrix_"+test.id
            try reporter.run(QualificationCase(id,"Discover bootstrapped DML schema: "+test.id)) {
                if f.profile == .forward { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+(test.rowMetadata ?? f.variant.metadata)) }
                for role in LabProfile.Role.allCases {
                    _ = try f.sql(role,f.profile.session(role)+"USE poc; SET sql_log_bin=0; DROP TABLE IF EXISTS \(table); CREATE TABLE \(table)(\(test.definition)) ENGINE=\(f.profile.engine(role)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin; "+test.setup)
                }
                let columns=try f.sql(.source,"SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='poc' AND TABLE_NAME='matrix_\(test.id)' ORDER BY ORDINAL_POSITION").split(separator:"\n")
                let fields=columns.map { "IFNULL(HEX(CAST(`"+$0.replacingOccurrences(of:"`",with:"``")+"` AS BINARY)),'<NULL>')" }.joined(separator:",")
                for (ordinal,phase) in test.phases.enumerated() {
                    let label=id+"-\(ordinal+1)"
                    try reporter.run(QualificationCase(label,"Bootstrapped DML phase \(ordinal+1): "+test.id)) {
                        let before=try f.boundary()
                        // Replicated and bootstrapped LOAD DATA run in the same fixture.
                        let sql=phase.sql.replacingOccurrences(of:"/replicator-dml.tsv",with:"/replicator-bootstrap-dml.tsv")
                        _ = try f.sql(.source,session+"USE poc; "+sql)
                        let end=try f.boundary()
                        let delta=try f.sql(.source,"SELECT GTID_SUBTRACT('\(end.gtids)','\(before.gtids)')")
                        let count=try DMLCompatibilityCases.transactionCount(delta)
                        if count>0 {
                            let config=isolated.configuration(label,at:before,count:count)
                            let client=try isolated.start(label,config:config)
                            _ = try isolated.finish(client,label:label,config:config)
                            try require(isolated.state(label,"SELECT lifecycle||'|'||transactions_applied||'|'||applied_position FROM state") == "STOPPED|\(count)|\(end.position)","bootstrap checkpoint differs")
                        }
                        try f.awaitNative()
                        var observed: [String:String] = [:]
                        for role in LabProfile.Role.allCases {
                            try require(f.sql(role,f.profile.session(role)+"USE poc; "+phase.check) == "1","independent bootstrap expectation failed: "+role.rawValue)
                            observed[role.rawValue]=try f.sql(role,f.profile.session(role)+"SELECT \(fields) FROM \(table) ORDER BY \(test.orderBy)",preserveWhitespace:true)
                        }
                        try require(Set(observed.values).count == 1,"bootstrap exact row bytes differ")
                        try writeJSON(["sql":sql,"check":phase.check,"observations":observed,"source_before":before.json,"source_after":end.json,"gtid_count":count],to:f.output.appendingPathComponent(label+"-comparison.json"))
                    }
                }
            }
        }
        if f.profile == .forward { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+f.variant.metadata) }
    }
}
