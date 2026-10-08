import Foundation

/// Reuses the forward profile's SQL/expectations. Only endpoint, engine and
/// source-version setup differ. Filter/refusal experiments explicitly seed
/// unlogged snapshots; their measured workloads execute only on the source.
public enum SharedCorrectness {
    public static func run(root: URL, arguments: [String]) throws {
        var args=arguments, build=true, slice="all"
        while !args.isEmpty {
            let flag=args.removeFirst()
            if flag == "--skip-build" { build=false }
            else if flag == "--slice", !args.isEmpty { slice=args.removeFirst() }
            else { throw LabError("reverse-correctness accepts --skip-build and --slice all|database|ddl|dml|indexes|policy|rejections") }
        }
        try require(["all","database","ddl","dml","indexes","policy","rejections"].contains(slice),"invalid reverse correctness slice")
        let run=Run(root:root)
        try run.execute(build:build,slice:slice)
    }

    final class Run {
        let f: LabFixture
        let applier: LabApplier
        let reporter: QualificationReporter
        var observation=0
        var currentDatabase="reverse_poc"
        var session: String { f.profile.session }
        let selected: Set<String>?
        var nativeInnoDB=false
        var referenceDecoderVersion=""
        func selects(_ id: String) -> Bool { selected?.contains(id) ?? true }
        init(root: URL, profile: LabProfile = .reverse, selected: Set<String>? = nil,
             category: String = "reverse-correctness", image: String = "mysql-replicator-packaging:reverse", codeCoverage: Bool = false, variant: LabVariant = .standard) {
            self.selected=selected
            f=LabFixture(root:root,category:category,image:image,profile:profile,codeCoverage:codeCoverage,variant:variant)
            applier=LabApplier(f)
            reporter=QualificationReporter(output:f.output,log:f.stage)
        }
        func execute(build: Bool, slice: String) throws {
            if slice == "all" && (selects(DDLCoverageCases.positive.id) || selects("myisam-recovery") || selects(DDLCoverageCases.group.id) || selects(DDLCoverageCases.wildcardFilter.id) || ModifyIndexCases.cases.contains(where:{selects($0.test.id)})) || slice == "indexes" {
                referenceDecoderVersion=try f.runner.run([f.h.decoder,"--no-defaults","--version"]).text
                try require(referenceDecoderVersion.contains("Ver 8.4."),"Independent binlog comparisons require MySQL 8.4 mysqlbinlog; set MYSQLBINLOG")
            }
            var report: [String:Any] = ["result":"failed","profile":f.profile.rawValue,"topology":f.profile.topology,"variant":f.variant.rawValue,"slice":slice,
                "scope":"Shared replicated and bootstrapped DML, ordered DDL, collation, failure and discovery fixtures; explicit capture variant. Native reference is profile-specific.",
                "adaptations":["Source-version session settings and explicit temporary-table engine are declared in the fixtures", "Source/target/native table engines are checked before comparing normalized metadata"],
                "not_covered":["Foreign keys/cascades are tested as refusals, not supported behavior", "Reconnect uses the separate lifecycle suite; reverse audited recovery retains its dedicated runner", "SIGKILL paths have behavioral assertions but cannot flush LLVM coverage"]]
            var failure: Error?
            let catalogInputs=try DDLCoverageEvidence.inputs(root:f.h.root)
            let catalogContracts=try DDLCoverageEvidence.hashes(root:f.h.root,paths:DDLCoverageEvidence.contractPaths)
            var catalogRuntime: [String:Any]?
            do {
                try f.prepare(build:build)
                try f.recordRuntime()
                if let profile=f.variant.catalogProfile {
                    catalogRuntime=try DDLCoverageEvidence.runtime(f.h,image:f.image,profileID:profile,inventory:DDLCoverage.load(directory:f.h.root.appendingPathComponent("tests/DDLCoverage")),inputDigest:DDLCoverageEvidence.digest(catalogInputs))
                }
                f.clients.append(applier.name)
                var source=f.config["source"] as! [String:Any]
                source.removeValue(forKey:"stopAfterTransactions"); f.config["source"]=source
                try f.installConfig(); try applier.ensureIdleContainer(); try applier.start(initialize:true)
                if slice == "all" || slice == "database" { try databases() }
                if slice == "all" || slice == "ddl" { try ddl() }
                if slice == "all" || slice == "dml" { try dml() }
                if slice == "all" || slice == "indexes" { try indexes() }
                if slice == "all" || slice == "policy" { try policies() }
                try applier.drain()
                _ = try f.docker(["cp",f.helper+":/evidence/state",f.output.path])
                let state=f.output.appendingPathComponent("state/state.sqlite").path
                let saved=try f.runner.run(["sqlite3",state,"SELECT lifecycle FROM state; SELECT COUNT(*) FROM ddl_intents WHERE status!='DONE'; SELECT COUNT(*) FROM row_intents WHERE status!='DONE'"]).text
                try require(saved == "STOPPED\n0\n0","unclean final checkpoint or unfinished intents: " + saved)
                if f.profile == .reverse && selects("ddl-compat-temporary") && (slice == "all" || slice == "ddl") {
                    let count=try f.runner.run(["sqlite3",state,"SELECT COUNT(*) FROM ddl_skips WHERE reason='row replication temporary-table cleanup'"]).text
                    try require((Int(count) ?? 0) > 0,"temporary-table cleanup missing from durable audit")
                }
                // Reopen all saved schema history, then apply another transaction.
                try applier.start(initialize:false)
                try step("INSERT INTO reverse_poc.aux VALUES(99,1)",database:"reverse_poc")
                try applier.drain()
                _ = try f.docker(["cp",f.helper+":/evidence/state",f.output.path])
                report["result"]="passed"; report["versions"]=f.versions; report["image"]=f.image
                report["summary"]=try applier.latestProgress()
                report["steps"]=observation
                if slice == "all" || slice == "rejections" { try rejections() }
                if slice == "all" {
                    try basicDML()
                    try bootstrapDML()
                    try dmlRefusals()
                    try orderedDDL()
                    try collationWorkflows()
                    try filters()
                    try indexResume()
                    try forwardFailures()
                    try myisamRecovery()
                }
            } catch {
                report["result"]="failed"
                report["error"]=String(describing:reporter.fail(error))
                _ = try? compare(currentDatabase)
                if let logs=try? f.h.compose(["logs","--no-color"]) { try? (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent("containers.log")) }
                if let boundary=try? f.boundary() {
                    try? writeJSON(boundary.json,to:f.output.appendingPathComponent("failed-source-boundary.json"))
                    if let raw=try? f.h.compose(["exec","-T",f.profile.service(.source),"cat","/var/lib/mysql/"+boundary.file]) {
                        try? raw.stdout.write(to:f.output.appendingPathComponent("failed-source.binlog"))
                    }
                }
                try? applier.drain()
                _ = try? f.docker(["cp",f.helper+":/evidence/state",f.output.path])
                report["cases"]=reporter.results
                try? writeJSON(report,to:f.output.appendingPathComponent("result.json"))
                failure=error
            }
            var cleanupErrors: [String]=[]
            do { try applier.drain(); try applier.archiveLogs() } catch { cleanupErrors.append(String(describing:error)) }
            if f.codeCoverage {
                do { try f.collectCoverage() } catch { cleanupErrors.append("coverage: "+String(describing:error)) }
            }
            do { try f.cleanup() } catch { cleanupErrors.append(String(describing:error)) }
            report["cleanup"]=cleanupErrors.isEmpty ? "passed" : cleanupErrors.joined(separator:"; ")
            if !cleanupErrors.isEmpty { report["result"]="failed"; if failure == nil { failure=LabError(cleanupErrors.joined(separator:"; ")) } }
            report["cases"]=reporter.results
            try writeJSON(report,to:f.output.appendingPathComponent("result.json"))
            if let runtime=catalogRuntime, let profile=f.variant.catalogProfile {
                try SharedCatalogSupport.export(root:f.h.root,output:f.output,profile:profile,inputs:catalogInputs,contracts:catalogContracts,runtime:runtime,results:reporter.results,result:report)
            }
            if let failure { throw failure }
            f.stage("PASS: shared correctness fixtures and saved-schema restart (\(observation) steps)")
        }
        func wait() throws {
            let end=try f.boundary(), deadline=Date().addingTimeInterval(60)
            try writeJSON(end.json,to:f.output.appendingPathComponent("awaited-source-boundary.json"))
            while true {
                if let p=try applier.latestProgress(), let gtids=p["appliedGTIDSet"] as? String,
                   try f.sql(.source,"SELECT GTID_SUBSET('\(end.gtids)','\(gtids)')") == "1" { break }
                let logs=try applier.logs(tail:true)
                try require(logs.stderr.isEmpty,"applier failed: " + String(decoding:logs.stderr,as:UTF8.self))
                try require(Date() < deadline,"applier failed to reach source GTID; inspect logs")
                Thread.sleep(forTimeInterval:0.1)
            }
            try f.awaitNative()
        }
        @discardableResult
        func step(_ sql: String, database: String, checks: [DDLCompatibilityCases.Check] = [], warning: Int? = nil, checkWarnings: Bool = false) throws -> [String:Any] {
            currentDatabase=database
            observation += 1
            let file=f.output.appendingPathComponent(String(format:"step-%04d.json",observation))
            try writeJSON(["sql":sql,"status":"running"],to:file)
            let warnings=try f.sql(.source,session+"\n"+sql+(checkWarnings ? "; SHOW WARNINGS" : ""))
            if checkWarnings { try require(warning.map { warnings.hasPrefix("Note\t\($0)\t") } ?? warnings.isEmpty,"unexpected source warnings: "+warnings) }
            try wait()
            var results: [[String:Any]]=[]
            for check in checks {
                var values: [String:String]=[:]
                for role in LabProfile.Role.allCases {
                    let service=role.rawValue
                    let value=try f.sql(role,"SET NAMES utf8mb4; SET SESSION time_zone='+00:00'; "+check.sql,preserveWhitespace:true)
                    values[service]=value
                    try require(value == check.expected,"\(service) expectation: \(check.sql) got \(value), expected \(check.expected)")
                }
                results.append(["query":check.sql,"expected":check.expected,"values":values])
            }
            let snapshots=try compare(database)
            let result: [String:Any] = ["sql":sql,"status":"passed","checks":results,"snapshots":snapshots,"warnings":warnings]
            try writeJSON(result,to:file)
            return result
        }
        func compare(_ database: String) throws -> [String:Any] {
            // Fixture-controlled names only. Compare exact row bytes and stable
            // schema properties; normalize integer display widths, not semantics.
            var values: [String:[String:String]]=[:]
            var rawTables: [String:String]=[:]
            let condition="TABLE_SCHEMA='\(database)'"
            for role in LabProfile.Role.allCases {
                    let service=role.rawValue
                func sql(_ statement: String, preserveWhitespace: Bool = false) throws -> String {
                    try f.sql(role,"SET NAMES utf8mb4; "+statement,preserveWhitespace:preserveWhitespace)
                }
                var snapshot: [String:String]=[:]
                snapshot["database"]=try sql("SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='\(database)'")
                snapshot["tables"]=try sql("SELECT TABLE_NAME,TABLE_TYPE,IFNULL(ENGINE,''),IFNULL(TABLE_COLLATION,'') FROM information_schema.TABLES WHERE \(condition) ORDER BY TABLE_NAME")
                let actualTables=snapshot["tables"]!
                rawTables[service]=actualTables
                try actualTables.write(to:f.output.appendingPathComponent("tables-"+service+".tsv"),atomically:true,encoding:.utf8)
                snapshot["tables"]=try actualTables.components(separatedBy:"\n").map { line in
                    var fields=line.components(separatedBy:"\t")
                    if fields.count >= 4 && fields[1] == "BASE TABLE" {
                        let explicitTemporaryClone=f.profile == .forward && role == .source && database == "ddlcompat" && fields[0] == "cloned"
                        let expected=explicitTemporaryClone ? "MyISAM" : role == .native && nativeInnoDB ? "InnoDB" : f.profile.engine(role)
                        try require(fields[2] == expected,"unexpected \(service) engine: " + fields[2])
                        fields[2]="<profile-engine>"
                    }
                    return fields.joined(separator:"\t")
                }.joined(separator:"\n")
                let columns=try sql("SELECT TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,IS_NULLABLE,IFNULL(CHARACTER_SET_NAME,''),IFNULL(COLLATION_NAME,''),IFNULL(COLUMN_DEFAULT,'<NULL>'),EXTRA,GENERATION_EXPRESSION FROM information_schema.COLUMNS WHERE \(condition) ORDER BY TABLE_NAME,ORDINAL_POSITION",preserveWhitespace:true)
                snapshot["columns"]=try ReverseSchemaComparison.columns(columns,mysql84:f.profile.version(role) == "8.4")
                snapshot["indexes"]=try sql("SELECT TABLE_NAME,INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,0),INDEX_TYPE,COLLATION FROM information_schema.STATISTICS WHERE \(condition) ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX")
                snapshot["partitions"]=try ReverseSchemaComparison.partitions(sql("SELECT TABLE_NAME,IFNULL(PARTITION_NAME,''),IFNULL(PARTITION_METHOD,''),IFNULL(PARTITION_EXPRESSION,''),IFNULL(PARTITION_DESCRIPTION,'') FROM information_schema.PARTITIONS WHERE \(condition) AND TABLE_NAME IN (SELECT TABLE_NAME FROM information_schema.TABLES WHERE \(condition) AND TABLE_TYPE='BASE TABLE') ORDER BY TABLE_NAME,PARTITION_ORDINAL_POSITION",preserveWhitespace:true))
                let tables=snapshot["tables"]!.components(separatedBy:"\n").map { $0.components(separatedBy:"\t") }.filter { $0.count >= 2 && $0[1] == "BASE TABLE" }.map { $0[0] }
                let columnRows=columns.components(separatedBy:"\n").map { $0.components(separatedBy:"\t") }
                let indexRows=snapshot["indexes"]!.components(separatedBy:"\n").map { $0.components(separatedBy:"\t") }
                var rowQueries: [String]=[]
                for table in tables {
                    let names=columnRows.filter { $0.count >= 2 && $0[0] == table }.map { $0[1] }
                    let expressions=names.map { "IFNULL(HEX(CAST(`\($0)` AS BINARY)),'<NULL>')" }.joined(separator:",")
                    let keys=indexRows.filter { $0.count >= 5 && $0[0] == table && $0[1] == "PRIMARY" }.map { "`\($0[4])`" }.joined(separator:",")
                    try require(!keys.isEmpty,"fixture table missing primary key")
                    rowQueries.append("SELECT '\(table)',\(expressions) FROM `\(database)`.`\(table)` ORDER BY \(keys)")
                }
                snapshot["rows"]=rowQueries.isEmpty ? "" : try sql("SET time_zone='+00:00'; "+rowQueries.joined(separator:"; "),preserveWhitespace:true)
                values[service]=snapshot
            }
            try writeJSON(values,to:f.output.appendingPathComponent("latest-comparison.json"))
            for service in ["native","target"] {
                for (key,value) in values["source"]! {
                    try require(values[service]?[key] == value,"\(database) \(service) \(key) differs; inspect latest-comparison.json")
                }
            }
            return ["normalized":values,"raw_tables":rawTables]
        }
        func databases() throws {
            try step("CREATE DATABASE otherdb CHARACTER SET latin1 COLLATE latin1_bin",database:"otherdb")
            for test in DatabaseCreationCases.cases where selects(test.test.id) {
                try reporter.run(test.test) {
                    let prefix=f.profile == .reverse ? test.prefix57 : test.prefix
                    let before=try applier.latestProgress() ?? [:]
                    let observation=try step(prefix+test.sql,database:test.database,checks:[.init(test.metadataSQL,test.expected)],warning:test.existing ? 1007 : nil,checkWarnings:true)
                    let table=test.database+".probe"
                    if !test.existing { try step("CREATE TABLE \(table)(id INT PRIMARY KEY,note VARCHAR(20))",database:test.database) }
                    try assertion("schema-effects",caseID:test.test.id) {
                        var values: [String:Any] = ["source_observation":observation]
                        for role in LabProfile.Role.allCases {
                            let metadata=try f.sql(role,test.metadataSQL)
                            let columns=try f.sql(role,"SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE,COLUMN_KEY,IFNULL(COLLATION_NAME,'') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='\(test.database)' AND TABLE_NAME='probe' ORDER BY ORDINAL_POSITION")
                            let engine=try f.sql(role,"SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='\(test.database)' AND TABLE_NAME='probe'")
                            try require(metadata == test.expected && columns == "id\tint\tNO\tPRI\t\nnote\tvarchar\tYES\t\t"+test.collation && engine == f.profile.engine(role),"database/table inheritance differs")
                            values[role.rawValue]=["database":metadata,"columns":columns,"engine":engine]
                        }
                        return values
                    }
                    try assertion("following-dml",caseID:test.test.id) {
                        let insert=test.existing ? "INSERT INTO \(table) VALUES(2,NULL)" : "INSERT INTO \(table) VALUES(1,'seed'),(2,NULL)"
                        try step(insert,database:test.database)
                        try step("UPDATE \(table) SET id=3,note=CONVERT(0xF09F9880 USING utf8mb4) WHERE id=2",database:test.database)
                        try step("DELETE FROM \(table) WHERE id=3",database:test.database)
                        let summary=try applier.latestProgress() ?? [:]
                        try require((summary["rowsApplied"] as? Int ?? 0)-(before["rowsApplied"] as? Int ?? 0) == (test.existing ? 3 : 4),"database following row count differs")
                        var rows: [String:String] = [:]
                        for role in LabProfile.Role.allCases {
                            rows[role.rawValue]=try f.sql(role,"SELECT id,HEX(note) FROM \(table) ORDER BY id")
                            try require(rows[role.rawValue] == "1\t73656564","database creation lost existing/following rows")
                        }
                        return rows
                    }
                    try applier.drain()
                    let saved=try snapshot(test.test.id)
                    let quoted=test.sql.replacingOccurrences(of:"'",with:"''")
                    try require(state(saved,"SELECT COUNT(*) FROM ddl_intents WHERE database_json IS NOT NULL AND before_schema_id IS NULL AND after_schema_id IS NULL AND status='DONE' AND target_sql='\(quoted)'") == "1","database DDL intent differs")
                    let end=try f.boundary(), result=try applier.latestProgress() ?? [:]
                    try require(result["appliedGTIDSet"] as? String == end.gtids,"database GTIDs differ")
                    try require((result["ddlApplied"] as? Int ?? 0)-(before["ddlApplied"] as? Int ?? 0) == (test.existing ? 1 : 2),"database DDL count differs")
                    try require((result["transactionsApplied"] as? Int ?? 0)-(before["transactionsApplied"] as? Int ?? 0) == (test.existing ? 4 : 5),"database transaction count differs")
                    try require(state(saved,"SELECT lifecycle||'|'||applied_file||'|'||applied_position FROM state") == "STOPPED|\(end.file)|\(end.position)","database checkpoint differs")
                    try applier.start(initialize:false)
                    try wait()
                }
            }
            if f.profile == .reverse && selects("reverse-database-table-defaults") { try reporter.run(QualificationCase("reverse-database-table-defaults","Preserve 5.7 utf8mb4 defaults through CREATE, LIKE, implicit DDL commit and RENAME")) {
                try step("CREATE TABLE created_charset.t(id INT PRIMARY KEY,n VARCHAR(20))",database:"created_charset")
                try step("CREATE TABLE created_charset.explicit_charset(id INT PRIMARY KEY,n VARCHAR(20)) ENGINE=InnoDB CHARACTER SET utf8mb4",database:"created_charset")
                try step("CREATE TABLE created_charset.explicit_default(id INT PRIMARY KEY,n INT) ENGINE='DEFAULT'",database:"created_charset")
                try step("START TRANSACTION; INSERT INTO created_charset.t VALUES(1,'before'); INSERT INTO created_charset.explicit_default VALUES(1,7); ALTER TABLE created_charset.t ADD extra INT DEFAULT 3; INSERT INTO created_charset.t(id,n) VALUES(2,'after')",database:"created_charset",checks:[.init("SELECT id,n,extra FROM created_charset.t ORDER BY id","1\tbefore\t3\n2\tafter\t3")])
                try step("CREATE TABLE created_charset.copy LIKE created_charset.t",database:"created_charset")
                try step("INSERT INTO created_charset.copy SELECT * FROM created_charset.t WHERE id=2",database:"created_charset")
                try step("RENAME TABLE created_charset.t TO created_charset.old, created_charset.copy TO created_charset.t",database:"created_charset",checks:[.init("SELECT id,n,extra FROM created_charset.t","2\tafter\t3")])
                try step("DROP TABLE created_charset.old",database:"created_charset")
            } }
        }
        func ddl() throws {
            for test in DDLCompatibilityCases.cases where selects(test.test.id) {
                nativeInnoDB=test.nativeInnoDB
                try setNativeEngine(nativeInnoDB ? "InnoDB" : "MyISAM")
                try reporter.run(test.test) {
                    try step("DROP DATABASE IF EXISTS ddlcompat",database:"ddlcompat")
                    try step("CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",database:"ddlcompat")
                    if test.test.id == "ddl-compat-temporary" {
                        try step("CREATE TABLE ddlcompat.tmp(id INT PRIMARY KEY,n INT)",database:"ddlcompat")
                        try step("INSERT INTO ddlcompat.tmp VALUES(99,99)",database:"ddlcompat")
                    }
                    let before=try applier.latestProgress() ?? [:], begin=try f.boundary()
                    for item in test.steps {
                        let sql=f.profile == .reverse ? item.sql57 : item.sql
                        if test.test.id == "ddl-compat-database" && sql == "DROP DATABASE ddlcompat" {
                            // Neither table is rediscovered by DML after resume.
                            // DROP must still retire both durable schema records.
                            try applier.drain()
                            let checkpoint=try snapshot("database-before-drop")
                            try require(state(checkpoint,"SELECT COUNT(*) FROM schemas WHERE current=1 AND json_extract(schema_json,'$.database')='ddlcompat'") == "2","database resume fixture lacks both saved schemas")
                            try applier.start(initialize:false); try wait()
                        }
                        try step(sql,database:"ddlcompat",checks:item.checks)
                    }
                    try applier.drain()
                    let end=try f.boundary(), result=try applier.latestProgress() ?? [:]
                    let count=try DMLCompatibilityCases.transactionCount(f.sql(.source,"SELECT GTID_SUBTRACT('\(end.gtids)','\(begin.gtids)')"))
                    if f.profile == .forward { try require(count == test.steps.reduce(0,{$0+$1.transactions}),"compatibility source event count differs") }
                    try require((result["transactionsApplied"] as? Int ?? 0)-(before["transactionsApplied"] as? Int ?? 0) == count && result["appliedGTIDSet"] as? String == end.gtids,"compatibility checkpoint differs")
                    let saved=try snapshot(test.test.id)
                    try require(state(saved,"SELECT COUNT(*) FROM ddl_intents WHERE status!='DONE'") == "0","unfinished compatibility DDL")
                    if test.test.id == "ddl-compat-database" {
                        try require(state(saved,"SELECT COUNT(*) FROM schemas WHERE current=1 AND json_extract(schema_json,'$.database')='ddlcompat'") == "1","DROP DATABASE left current schemas")
                    }
                    try applier.start(initialize:false); try wait()
                }
            }
        }
        func dml() throws {
            try resetNativeEngine()
            try step("CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",database:"poc")
            for test in DMLCompatibilityCases.cases where selects("matrix-"+test.id) {
                try reporter.run(QualificationCase("matrix-"+test.id,"Shared DML matrix: "+test.id)) {
                    if f.profile == .forward { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+(test.rowMetadata ?? f.variant.metadata)) }
                    try step("CREATE TABLE poc.matrix_\(test.id)(\(test.definition)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin",database:"poc")
                    if !test.setup.isEmpty { try step(test.setup,database:"poc") }
                    for phase in test.phases { try step("USE poc; "+phase.sql,database:"poc",checks:[.init(phase.check,"1")]) }
                }
            }
        }
        func indexes() throws {
            if f.profile == .forward { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+f.variant.metadata) }
            try resetNativeEngine()
            for test in ModifyIndexCases.cases where selects(test.test.id) {
                try reporter.run(test.test) {
                    try step("CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",database:"demo")
                    // Seed only on the source, through replication. Split the
                    // fixed fixture preamble so multi-table DROP stays outside
                    // the current DDL grammar while testing each actual DROP.
                    for name in ["mi_clone","mi_renamed","mi","explicit_default_engine"] { try step("DROP TABLE IF EXISTS demo.\(name)",database:"demo") }
                    let parts=test.seed.components(separatedBy:"; ").filter { !$0.hasPrefix("SET SESSION") && !$0.hasPrefix("CREATE DATABASE") && !$0.hasPrefix("DROP TABLE") && !$0.isEmpty }
                    for sql in parts { try step(sql,database:"demo") }
                    var starts: [LabProfile.Role:Boundary] = [:]
                    for role in LabProfile.Role.allCases { starts[role]=try f.boundary(role) }
                    let before=try applier.latestProgress() ?? [:]
                    try assertion("schema-effects",caseID:test.test.id) {
                        let observation=try step(test.sql,database:"demo",checks:[.init("SELECT id,IFNULL(HEX(name),'NULL'),IFNULL(CAST(n AS CHAR),'NULL'),IFNULL(HEX(b),'NULL') FROM demo.\(test.table) ORDER BY id",test.retained)],checkWarnings:true)
                        var values: [String:Any] = ["source_observation":observation]
                        for role in LabProfile.Role.allCases {
                            values[role.rawValue]=try ModifyIndexCases.metadata(f.h,f.profile.service(role),test,expectedEngine:f.profile.engine(role))
                        }
                        return values
                    }
                    if !test.workload.isEmpty {
                        try assertion("following-dml",caseID:test.test.id) {
                            var observed: [[String:Any]] = []
                            for item in test.workload { observed.append(try step(item.sql,database:"demo",checks:[.init("SELECT id,IFNULL(HEX(name),'NULL'),IFNULL(CAST(n AS CHAR),'NULL'),IFNULL(HEX(b),'NULL') FROM demo.\(test.table) ORDER BY id",item.rows)])) }
                            return observed
                        }
                    }
                    try applier.drain()
                    let saved=try snapshot(test.test.id), end=try f.boundary()
                    let result=try applier.latestProgress() ?? [:]
                    try assertion("source-boundary",caseID:test.test.id) {
                        for (key,expected) in [("transactionsApplied",1+test.workload.count),("rowsApplied",test.workload.reduce(0,{$0+$1.affectedRows})),("ddlApplied",1)] {
                            try require((result[key] as? Int ?? 0)-(before[key] as? Int ?? 0) == expected,"MODIFY/index counter differs: "+key)
                        }
                        try require(result["appliedGTIDSet"] as? String == end.gtids,"MODIFY/index GTIDs differ")
                        let checkpoint=try state(saved,"SELECT lifecycle||'|'||applied_file||'|'||applied_position FROM state")
                        try require(checkpoint == "STOPPED|\(end.file)|\(end.position)","MODIFY/index checkpoint differs")
                        return ["source":end.json,"saved":checkpoint,"summary":result]
                    }
                    try assertion("schema-history",caseID:test.test.id) {
                        let quoted=test.sql.replacingOccurrences(of:"'",with:"''")
                        let intent=try state(saved,"SELECT status||'|'||target_sql FROM ddl_intents ORDER BY rowid DESC LIMIT 1")
                        try require(intent == "DONE|"+test.sql,"DDL rewritten or incomplete")
                        let references=try state(saved,"SELECT COUNT(*) FROM row_intents r JOIN schemas s ON s.id=r.schema_id WHERE s.current=1 AND r.status='DONE' AND r.schema_id=(SELECT after_schema_id FROM ddl_intents WHERE target_sql='\(quoted)' ORDER BY rowid DESC LIMIT 1)")
                        try require(references == String(test.workload.reduce(0,{$0+$1.affectedRows})),"following rows did not use published schema")
                        let history=try state(saved,"SELECT schema_json FROM schemas WHERE id=(SELECT after_schema_id FROM ddl_intents ORDER BY rowid DESC LIMIT 1)")
                        let schema=try JSONSerialization.jsonObject(with:Data(history.utf8)) as? [String:Any]
                        try require((schema?["columns"] as? [[String:Any]])?.count == 4 && schema?["secondaryIndexes"] is [[String:Any]],"extended schema metadata missing")
                        try require(state(saved,"PRAGMA user_version") == "9","state version gate differs")
                        return ["intent":intent,"schema":schema ?? [:],"following_row_intents":references] as [String:Any]
                    }
                    try assertion("normalized-binlog",caseID:test.test.id) { try binlogAssertion(test,starts:starts) }
                    try applier.start(initialize:false)
                    try wait()
                }
            }
        }
        func resetNativeEngine() throws {
            nativeInnoDB=false
            try setNativeEngine("MyISAM")
        }
        func setNativeEngine(_ engine: String) throws {
            guard f.profile == .forward else { return }
            // A running SQL thread retains its session default. Restart it only
            // after catching up, so the next scenario uses the declared engine.
            try f.awaitNative()
            _ = try f.sql(.native,"STOP REPLICA SQL_THREAD; SET GLOBAL default_storage_engine="+engine+"; START REPLICA SQL_THREAD")
        }
        func policies() throws {
            guard selects(DDLCompatibilityCases.skipTrigger.id) else { return }
            try resetNativeEngine()
            try reporter.run(DDLCompatibilityCases.skipTrigger) {
                try step("CREATE DATABASE policy CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",database:"policy")
                try step("CREATE TABLE policy.t(id INT PRIMARY KEY,n INT)",database:"policy")
                try step("CREATE TRIGGER policy.tr BEFORE INSERT ON policy.t FOR EACH ROW SET NEW.n=7",database:"policy")
                try step("INSERT INTO policy.t VALUES(1,1)",database:"policy",checks:[.init("SELECT * FROM policy.t","1\t7")])
                try require(try f.sql(.target,"SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='policy'") == "0","trigger installed on external target")
                try step("DROP TRIGGER policy.tr",database:"policy")
            }
        }
    }
}
