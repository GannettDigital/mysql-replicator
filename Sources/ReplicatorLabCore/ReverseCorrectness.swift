import Foundation

/// Reuses the forward profile's SQL/expectations. Only endpoint, engine and
/// source-version setup differ; no workload is executed directly on the target.
public enum ReverseCorrectness {
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
        let f: ReverseFixture
        let applier: ReverseDemoApplier
        let reporter: QualificationReporter
        var observation=0
        var currentDatabase="reverse_poc"
        let session="SET NAMES utf8mb4 COLLATE utf8mb4_bin; SET SESSION time_zone='+00:00'; SET SESSION sql_mode='STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION,NO_AUTO_CREATE_USER'; "
        init(root: URL) {
            f=ReverseFixture(root:root,category:"reverse-correctness")
            applier=ReverseDemoApplier(f)
            reporter=QualificationReporter(output:f.output,log:f.stage)
        }
        func execute(build: Bool, slice: String) throws {
            var report: [String:Any] = ["result":"failed","profile":"mysql57-to-mysql84-innodb","slice":slice,
                "scope":"Shared positive DML matrix, DDL compatibility, database creation and modify/index fixtures; GTID only. Native reference is 5.7 InnoDB.",
                "adaptations":["5.7 has no binlog_row_metadata or default_collation_for_utf8mb4 setting", "Temporary CREATE LIKE uses InnoDB for this engine profile"],
                "not_covered":["Forward-only 8.4 collations/translation and MyISAM index limits", "File-position mode", "Foreign keys/cascades", "Forward reconnect/filter/timeout scenarios; reverse crash recovery remains separate"]]
            defer { try? applier.archiveLogs(); try? f.cleanup() }
            do {
                try f.prepare(build:build)
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
                if slice == "all" || slice == "ddl" {
                    let count=try f.runner.run(["sqlite3",state,"SELECT COUNT(*) FROM ddl_skips WHERE reason='row replication temporary-table cleanup'"]).text
                    try require((Int(count) ?? 0) > 0,"temporary-table cleanup missing from durable audit")
                }
                // Reopen all saved schema history, then apply another transaction.
                try applier.start(initialize:false)
                try step("UPDATE reverse_poc.items SET amount=amount+1 WHERE id=1",database:"reverse_poc")
                try applier.drain()
                _ = try f.docker(["cp",f.helper+":/evidence/state",f.output.path])
                report["result"]="passed"; report["versions"]=f.versions; report["image"]=f.image
                report["summary"]=try applier.latestProgress()
                report["steps"]=observation
                if slice == "all" || slice == "rejections" { try rejections() }
            } catch {
                report["result"]="failed"
                report["error"]=String(describing:reporter.fail(error))
                _ = try? compare(currentDatabase)
                if let logs=try? f.h.compose(["logs","--no-color"]) { try? (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent("containers.log")) }
                if let boundary=try? f.h.boundary("target57") {
                    try? writeJSON(boundary.json,to:f.output.appendingPathComponent("failed-source-boundary.json"))
                    if let raw=try? f.h.compose(["exec","-T","target57","cat","/var/lib/mysql/"+boundary.file]) {
                        try? raw.stdout.write(to:f.output.appendingPathComponent("failed-source.binlog"))
                    }
                }
                try? applier.drain()
                _ = try? f.docker(["cp",f.helper+":/evidence/state",f.output.path])
                report["cases"]=reporter.results
                try? writeJSON(report,to:f.output.appendingPathComponent("result.json"))
                throw error
            }
            report["cases"]=reporter.results
            try writeJSON(report,to:f.output.appendingPathComponent("result.json"))
            f.stage("PASS: shared correctness fixtures and saved-schema restart (\(observation) steps)")
        }
        func wait() throws {
            let end=try f.h.boundary("target57"), deadline=Date().addingTimeInterval(60)
            try writeJSON(end.json,to:f.output.appendingPathComponent("awaited-source-boundary.json"))
            while true {
                if let p=try applier.latestProgress(), let gtids=p["appliedGTIDSet"] as? String,
                   try f.h.sql("target57","SELECT GTID_SUBSET('\(end.gtids)','\(gtids)')") == "1" { break }
                let logs=try applier.logs(tail:true)
                try require(logs.stderr.isEmpty,"applier failed: " + String(decoding:logs.stderr,as:UTF8.self))
                try require(Date() < deadline,"applier failed to reach source GTID; inspect logs")
                Thread.sleep(forTimeInterval:0.1)
            }
            try f.awaitNative()
        }
        func step(_ sql: String, database: String, checks: [DDLCompatibilityCases.Check] = []) throws {
            currentDatabase=database
            observation += 1
            let file=f.output.appendingPathComponent(String(format:"step-%04d.json",observation))
            try writeJSON(["sql":sql,"status":"running"],to:file)
            _ = try f.h.sql("target57",session+"\n"+sql)
            try wait()
            var results: [[String:Any]]=[]
            for check in checks {
                var values: [String:String]=[:]
                for service in ["target57","native","source"] {
                    let value=try f.h.sql(service,"SET NAMES utf8mb4; SET SESSION time_zone='+00:00'; "+check.sql,preserveWhitespace:true)
                    values[service]=value
                    try require(value == check.expected,"\(service) expectation: \(check.sql) got \(value), expected \(check.expected)")
                }
                results.append(["query":check.sql,"expected":check.expected,"values":values])
            }
            let snapshots=try compare(database)
            try writeJSON(["sql":sql,"status":"passed","checks":results,"snapshots":snapshots],to:file)
        }
        func compare(_ database: String) throws -> [String:Any] {
            // Fixture-controlled names only. Compare exact row bytes and stable
            // schema properties; normalize integer display widths, not semantics.
            var values: [String:[String:String]]=[:]
            let condition="TABLE_SCHEMA='\(database)'"
            for service in ["target57","native","source"] {
                func sql(_ statement: String, preserveWhitespace: Bool = false) throws -> String {
                    try f.h.sql(service,"SET NAMES utf8mb4; "+statement,preserveWhitespace:preserveWhitespace)
                }
                var snapshot: [String:String]=[:]
                snapshot["database"]=try sql("SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='\(database)'")
                snapshot["tables"]=try sql("SELECT TABLE_NAME,TABLE_TYPE,IFNULL(ENGINE,''),IFNULL(TABLE_COLLATION,'') FROM information_schema.TABLES WHERE \(condition) ORDER BY TABLE_NAME")
                let columns=try sql("SELECT TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,IS_NULLABLE,IFNULL(CHARACTER_SET_NAME,''),IFNULL(COLLATION_NAME,''),IFNULL(COLUMN_DEFAULT,'<NULL>'),EXTRA,GENERATION_EXPRESSION FROM information_schema.COLUMNS WHERE \(condition) ORDER BY TABLE_NAME,ORDINAL_POSITION",preserveWhitespace:true)
                snapshot["columns"]=try ReverseSchemaComparison.columns(columns,mysql84:service == "source")
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
            for service in ["native","source"] {
                for (key,value) in values["target57"]! {
                    try require(values[service]?[key] == value,"\(database) \(service) \(key) differs; inspect latest-comparison.json")
                }
            }
            return values
        }
        func databases() throws {
            try step("CREATE DATABASE otherdb CHARACTER SET latin1 COLLATE latin1_bin",database:"otherdb")
            for test in DatabaseCreationCases.cases {
                try reporter.run(test.test) {
                    let prefix=test.database == "created_charset" ? "" : test.prefix
                    try step(prefix+test.sql,database:test.database,checks:[.init(test.metadataSQL,test.expected)])
                }
            }
            try reporter.run(QualificationCase("reverse-database-table-defaults","Preserve 5.7 utf8mb4 defaults through CREATE, LIKE, implicit DDL commit and RENAME")) {
                try step("CREATE TABLE created_charset.t(id INT PRIMARY KEY,n VARCHAR(20))",database:"created_charset")
                try step("CREATE TABLE created_charset.explicit_charset(id INT PRIMARY KEY,n VARCHAR(20)) ENGINE=InnoDB CHARACTER SET utf8mb4",database:"created_charset")
                try step("CREATE TABLE created_charset.explicit_default(id INT PRIMARY KEY,n INT) ENGINE='DEFAULT'",database:"created_charset")
                try step("START TRANSACTION; INSERT INTO created_charset.t VALUES(1,'before'); INSERT INTO created_charset.explicit_default VALUES(1,7); ALTER TABLE created_charset.t ADD extra INT DEFAULT 3; INSERT INTO created_charset.t(id,n) VALUES(2,'after')",database:"created_charset",checks:[.init("SELECT id,n,extra FROM created_charset.t ORDER BY id","1\tbefore\t3\n2\tafter\t3")])
                try step("CREATE TABLE created_charset.copy LIKE created_charset.t",database:"created_charset")
                try step("INSERT INTO created_charset.copy SELECT * FROM created_charset.t WHERE id=2",database:"created_charset")
                try step("RENAME TABLE created_charset.t TO created_charset.old, created_charset.copy TO created_charset.t",database:"created_charset",checks:[.init("SELECT id,n,extra FROM created_charset.t","2\tafter\t3")])
                try step("DROP TABLE created_charset.old",database:"created_charset")
            }
        }
        func ddl() throws {
            for test in DDLCompatibilityCases.cases {
                try reporter.run(test.test) {
                    try step("DROP DATABASE IF EXISTS ddlcompat",database:"ddlcompat")
                    try step("CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",database:"ddlcompat")
                    if test.test.id == "ddl-compat-temporary" {
                        try step("CREATE TABLE ddlcompat.tmp(id INT PRIMARY KEY,n INT)",database:"ddlcompat")
                        try step("INSERT INTO ddlcompat.tmp VALUES(99,99)",database:"ddlcompat")
                    }
                    for item in test.steps {
                        let sql=test.test.id == "ddl-compat-temporary" ? item.sql.replacingOccurrences(of:"ENGINE=MyISAM",with:"ENGINE=InnoDB") : item.sql
                        try step(sql,database:"ddlcompat",checks:item.checks)
                    }
                }
            }
        }
        func dml() throws {
            try step("CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",database:"poc")
            for test in DMLCompatibilityCases.cases {
                try reporter.run(QualificationCase("matrix-"+test.id,"Shared DML matrix: "+test.id)) {
                    try step("CREATE TABLE poc.matrix_\(test.id)(\(test.definition)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin",database:"poc")
                    if !test.setup.isEmpty { try step(test.setup,database:"poc") }
                    for phase in test.phases { try step("USE poc; "+phase.sql,database:"poc",checks:[.init(phase.check,"1")]) }
                }
            }
        }
        func indexes() throws {
            for test in ModifyIndexCases.cases {
                try reporter.run(test.test) {
                    try step("CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",database:"demo")
                    // Seed only on the source, through replication. Split the
                    // fixed fixture preamble so multi-table DROP stays outside
                    // the current DDL grammar while testing each actual DROP.
                    for name in ["mi_clone","mi_renamed","mi","explicit_default_engine"] { try step("DROP TABLE IF EXISTS demo.\(name)",database:"demo") }
                    let parts=test.seed.components(separatedBy:"; ").filter { !$0.hasPrefix("SET SESSION") && !$0.hasPrefix("CREATE DATABASE") && !$0.hasPrefix("DROP TABLE") && !$0.isEmpty }
                    for sql in parts { try step(sql,database:"demo") }
                    try step(test.sql,database:"demo",checks:[.init("SELECT id,IFNULL(HEX(name),'NULL'),IFNULL(CAST(n AS CHAR),'NULL'),IFNULL(HEX(b),'NULL') FROM demo.\(test.table) ORDER BY id",test.retained)])
                    for service in ["target57","native","source"] { _ = try ModifyIndexCases.metadata(f.h,service,test,expectedEngine:"InnoDB") }
                    for item in test.workload { try step(item.sql,database:"demo",checks:[.init("SELECT id,IFNULL(HEX(name),'NULL'),IFNULL(CAST(n AS CHAR),'NULL'),IFNULL(HEX(b),'NULL') FROM demo.\(test.table) ORDER BY id",item.rows)]) }
                }
            }
        }
        func policies() throws {
            try reporter.run(DDLCompatibilityCases.skipTrigger) {
                try step("CREATE DATABASE policy CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",database:"policy")
                try step("CREATE TABLE policy.t(id INT PRIMARY KEY,n INT)",database:"policy")
                try step("CREATE TRIGGER policy.tr BEFORE INSERT ON policy.t FOR EACH ROW SET NEW.n=7",database:"policy")
                try step("INSERT INTO policy.t VALUES(1,1)",database:"policy",checks:[.init("SELECT * FROM policy.t","1\t7")])
                try require(try f.h.sql("source","SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='policy'") == "0","trigger installed on external target")
                try step("DROP TRIGGER policy.tr",database:"policy")
            }
        }
    }
}
