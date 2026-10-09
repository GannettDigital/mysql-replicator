import Foundation

extension SharedCorrectness.Run {
    /// One dependent workflow: selecting it always runs all 70 steps and the
    /// completion checks that gate its named catalog assertions.
    func orderedDDL() throws {
        guard selects(DDLCoverageCases.group.id) else { return }
        try resetNativeEngine()
        try f.awaitNative()
        for role in LabProfile.Role.allCases {
            _ = try f.sql(role,"SET sql_log_bin=0; DROP DATABASE IF EXISTS poc; DROP DATABASE IF EXISTS otherdb; CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE DATABASE otherdb CHARACTER SET latin1 COLLATE latin1_bin")
        }
        let isolated=LabIsolatedApply(f), changes=DDLCoverageCases.changes
        var starts: [LabProfile.Role:Boundary] = [:]
        for role in LabProfile.Role.allCases { starts[role]=try f.boundary(role) }
        let config=isolated.configuration("ddl",at:starts[.source]!,count:changes.count)
        try reporter.run(DDLCoverageCases.group) {
            let applying=try isolated.start("ddl",config:config)
            for (index,change) in changes.enumerated() {
                try reporter.run(change.test) {
                    let prefix=change.table=="defaults" ? (f.profile == .forward ? "SET SESSION default_collation_for_utf8mb4=utf8mb4_general_ci; " : "") : ""
                    let assertionID = DDLCoverageCases.assertion(for: change.test.id)
                    let warnings = try f.sql(.source,session+prefix+change.sql + (assertionID == nil ? "" : "; SHOW WARNINGS"))
                    try isolated.barrier(applying,count:index+1)
                    let boundary=try f.boundary()
                    try f.awaitNative()
                    func checkSchemaAndRows() throws -> Any {
                        var observations: [String: Any] = ["sql": change.sql, "source_warnings": warnings, "source_boundary": boundary.json]
                        if assertionID != nil {
                            let codes=try warnings.split(separator:"\n").map { line -> Int in
                                let fields=line.split(separator:"\t")
                                guard fields.count>=2,let code=Int(fields[1]) else {throw LabError("malformed source warning: \(line)")}
                                return code
                            }
                            try require(codes==change.warnings,"unexpected source warnings: \(warnings)")
                        }
                        for service in LabProfile.Role.allCases {
                            let schema=try f.sql(service,"SELECT GROUP_CONCAT(CONCAT(COLUMN_NAME,':',DATA_TYPE,':',IS_NULLABLE) ORDER BY ORDINAL_POSITION) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)'")
                            try require(schema == (change.schema.isEmpty ? "NULL" : change.schema),"\(service) schema differs")
                            if !change.schema.isEmpty {
                                let engine=try f.sql(service,"SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)'")
                                try require(engine == f.profile.engine(service),"DDL local engine selection differs")
                                if change.schema.contains("note:") {
                                    let collation=try f.sql(service,"SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)' AND COLUMN_NAME='note'")
                                    try require(collation == change.collation,"DDL collation differs")
                                }
                                let fields=change.schema.contains("b:varbinary") ? "id,IFNULL(HEX(b),'NULL')" : change.schema.contains("note:") ? "id,IFNULL(HEX(note),'NULL')"+(change.schema.contains("payload:") ? ",IFNULL(HEX(payload),'NULL')" : "") : "id,IFNULL(HEX(payload),'NULL')"
                                let rows=try f.sql(service,"SELECT \(fields) FROM \(change.database).\(change.table) ORDER BY id",preserveWhitespace:true)
                                try require(rows == change.rows,"\(service) rows differ")
                                try rows.write(to:f.output.appendingPathComponent("\(service.rawValue)-ddl-\(change.test.id).tsv"),atomically:true,encoding:.utf8)
                            }
                            if assertionID != nil {
                                let columns = try f.sql(service,"SELECT CONCAT(COLUMN_NAME,':',IF(DATA_TYPE IN ('int','bigint'),CONCAT(DATA_TYPE,IF(COLUMN_TYPE LIKE '%unsigned%',' unsigned','')),COLUMN_TYPE),':',IS_NULLABLE,':',IFNULL(COLUMN_DEFAULT,'<NULL>'),':',COLUMN_KEY,':',EXTRA,':',IFNULL(CHARACTER_SET_NAME,''),':',IFNULL(COLLATION_NAME,'')) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)' ORDER BY ORDINAL_POSITION")
                                let expected = change.exactColumns
                                try require(columns == expected, "\(service) exact column/default/key metadata differs: \(columns)")
                                let defaults = try f.sql(service,"SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)'")
                                try require(defaults == (change.schema.isEmpty ? "" : "utf8mb4_unicode_ci"), "\(service) table default collation differs")
                                observations[service.rawValue] = ["columns": columns, "table_collation": defaults, "schema": schema, "expected_rows": change.rows,
                                    "observed_rows": change.schema.isEmpty ? "" : try String(contentsOf: f.output.appendingPathComponent("\(service.rawValue)-ddl-\(change.test.id).tsv"), encoding: .utf8),
                                    "engine": try f.sql(service,"SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='\(change.table)'")]
                            }
                            if change.test.id=="rename-table" {try require(f.sql(service,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(change.database)' AND TABLE_NAME='changes'") == "0","renamed table remains")}
                        }
                        return observations
                    }
                    if let assertionID {
                        try reporter.assertion(assertionID, evidence: "assertions/" + change.test.id + "/" + assertionID + ".json", checkSchemaAndRows)
                    } else { _ = try checkSchemaAndRows() }
                }
            }
            let ddlEnd=try f.boundary()
            let ddlResult=try isolated.finish(applying,label:"ddl",config:config)
            try require(ddlResult["appliedGTIDSet"] as? String == ddlEnd.gtids,"DDL applied GTID coverage differs")
            let ddlCount=changes.filter{!$0.isDML}.count,rowCount=changes.filter{$0.isDML}.reduce(0){$0+$1.affectedRows}
            try require(ddlResult["ddlApplied"] as? Int == ddlCount && ddlResult["rowsApplied"] as? Int == rowCount,"DDL counters differ")
            try require(isolated.state("ddl","SELECT COUNT(*) FROM ddl_intents WHERE status='DONE'") == String(ddlCount),"DDL intent history missing")
            try require(isolated.state("ddl","SELECT COUNT(*) FROM ddl_intents WHERE target_sql LIKE 'CREATE TABLE IF NOT EXISTS%' AND before_schema_id IS NOT NULL AND before_schema_id=after_schema_id") == "3","conditional CREATE retired an unchanged schema")
            try require(isolated.state("ddl","SELECT COUNT(*) FROM ddl_intents WHERE target_sql LIKE 'DROP TABLE IF EXISTS%' AND before_schema_id IS NULL AND after_schema_id IS NULL AND status='DONE'") == "1","absent DROP did not complete its no-op intent")
            let expectedCreates=changes.filter{$0.sql.hasPrefix("CREATE TABLE")}.map{$0.sql}.joined(separator:"\n")
            try require(isolated.state("ddl","SELECT target_sql FROM ddl_intents WHERE target_sql LIKE 'CREATE TABLE%' ORDER BY rowid")==expectedCreates,"CREATE SQL was rewritten")
            try require(isolated.state("ddl","SELECT COUNT(*) FROM schemas WHERE current=1") == "0","dropped schema remains current")
            try require(isolated.state("ddl","SELECT COUNT(*) FROM row_intents r LEFT JOIN schemas s ON s.id=r.schema_id WHERE s.id IS NULL") == "0","row intent lost historical schema")
            for service in LabProfile.Role.allCases {
                let from=starts[service]!, end=try f.boundary(service)
                let file=f.output.appendingPathComponent(service.rawValue+"-ordered.binlog")
                try f.h.compose(["exec","-T",f.profile.service(service),"cat","/var/lib/mysql/"+from.file]).stdout.write(to:file)
                try require(from.file==end.file,"unexpected DDL binlog rotation")
                let decoded=try f.runner.run([f.h.decoder,"--no-defaults","--verify-binlog-checksum","--base64-output=DECODE-ROWS","-vv","--start-position=\(from.position)","--stop-position=\(end.position)",file.path])
                try decoded.stdout.write(to:f.output.appendingPathComponent(service.rawValue+"-ddl-binlog.txt"))
                let text=String(decoding:decoded.stdout,as:UTF8.self).uppercased()
                let expectedKinds=changes.flatMap {Array(repeating:String($0.sql.split(separator:" ")[0]),count:$0.isDML ? $0.affectedRows : 1)}
                let kinds=text.split(separator:"\n").compactMap {line -> String? in
                    for verb in ["CREATE TABLE","ALTER TABLE","RENAME TABLE","DROP TABLE","TRUNCATE TABLE"] {
                        if line.hasPrefix(verb+" ") {return String(verb.split(separator:" ")[0])}
                    }
                    for verb in ["INSERT INTO","UPDATE","DELETE FROM"] {
                        if line.hasPrefix("### "+verb+" ") {return String(verb.split(separator:" ")[0])}
                    }
                    return nil
                }
                try require(kinds==expectedKinds,"DDL/DML binlog operations differ in count or source order")
                try writeJSON(kinds,to:f.output.appendingPathComponent(service.rawValue+"-ddl-operation-kinds.json"))
            }

        }
    }
}
