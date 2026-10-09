import Foundation

extension SharedCorrectness.Run {
    /// Preserve the historical 8.4 metadata/discovery refusals. A 5.7 source
    /// cannot establish the same optional-label/0900 metadata contract.
    func dmlRefusals() throws {
        guard f.profile == .forward else { return }
        let chosen=DMLCompatibilityCases.rejections.filter { selects("matrix-reject-"+$0.id) }
        guard !chosen.isEmpty else { return }
        try resetNativeEngine(); try f.awaitNative()
        let isolated=LabIsolatedApply(f)
        for role in LabProfile.Role.allCases { _ = try f.sql(role,"SET sql_log_bin=0; CREATE DATABASE IF NOT EXISTS poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci") }
        for test in chosen {
            let label="matrix-reject-"+test.id, table="poc.matrix_reject_"+test.id.replacingOccurrences(of:"-",with:"_")
            try reporter.run(QualificationCase(label,"Refuse incompatible bootstrapped metadata: "+test.id)) {
                for role in LabProfile.Role.allCases {
                    let definition=role == .target ? test.targetDefinition : test.sourceDefinition
                    _ = try f.sql(role,f.profile.session(role)+"USE poc; SET sql_log_bin=0; DROP TABLE IF EXISTS \(table); CREATE TABLE \(table)(\(definition)) ENGINE=\(f.profile.engine(role))")
                }
                _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+test.rowMetadata)
                let before=try f.boundary()
                _ = try f.sql(.source,session+"USE poc; "+test.sourceSession+"INSERT INTO \(table) VALUES"+test.values)
                _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+f.variant.metadata)
                let config=isolated.configuration(label,at:before,count:1)
                let client=try isolated.start(label,config:config)
                let diagnostic=try isolated.finish(client,label:label,config:config,reason:test.reason)
                try require(f.sql(.target,"SELECT \(test.postWriteCheck ?? "COUNT(*)=0") FROM \(table)") == "1","rejected target effects differ")
                let saved=try isolated.state(label,"SELECT lifecycle||'|'||transactions_applied||'|'||COALESCE(applied_position,'NULL') FROM state")
                try require(saved == "BLOCKED|0|NULL","metadata rejection advanced durable progress")
                if test.postWriteCheck != nil {
                    try require(isolated.state(label,"SELECT COUNT(*) FROM row_intents WHERE status='PENDING'") == "1","generated mismatch lost pending evidence")
                }
                try f.awaitNative()
                try require(f.sql(.native,"SELECT COUNT(*) FROM \(table)") == "1","native did not accept source-compatible row")
                try writeJSON(["diagnostic":diagnostic,"state":saved,"source_before":before.json],to:f.output.appendingPathComponent(label+"-observations.json"))
            }
        }
    }
}
