import Foundation

extension LabDemo.Session {
    func observation(_ role: LabProfile.Role) throws -> [String: String] {
        let h=fixture!.h, service=profile.service(role)
        let schema = try h.sql(service, "SELECT t.TABLE_NAME,c.ORDINAL_POSITION,c.COLUMN_NAME,CONCAT(c.DATA_TYPE,IF(c.COLUMN_TYPE LIKE '%unsigned%',' unsigned','')),c.IS_NULLABLE,c.COLUMN_KEY,IFNULL(c.CHARACTER_MAXIMUM_LENGTH,0),IFNULL(c.COLLATION_NAME,'') FROM information_schema.TABLES t JOIN information_schema.COLUMNS c USING(TABLE_SCHEMA,TABLE_NAME) WHERE t.TABLE_SCHEMA='demo' ORDER BY t.TABLE_NAME,c.ORDINAL_POSITION", preserveWhitespace: true)
        let encoding = try h.sql(service, "SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='demo'")
        let engine = try h.sql(service, "SELECT TABLE_NAME,ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='demo' ORDER BY TABLE_NAME")
        let present = try h.sql(service, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='items'") == "1"
        var rows = ""
        if present {
            let hasNote = try h.sql(service, "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='items' AND COLUMN_NAME='note'") == "1"
            rows = try h.sql(service, "SELECT id,HEX(value),quantity" + (hasNote ? ",IFNULL(HEX(note),'NULL')" : "") + " FROM demo.items ORDER BY id", preserveWhitespace: true)
        }
        return ["schema": schema, "database": encoding, "engines": engine, "rows_hex": rows]
    }

    func checkpoint() throws -> String {
        try state("SELECT COALESCE(applied_file,'')||'|'||COALESCE(applied_position,'')||'|'||transactions_applied||'|'||rows_applied||'|'||ddl_applied FROM state")
    }
    func awaitApplied() throws {
        let f=fixture!, end=try f.boundary(), deadline=Date().addingTimeInterval(60)
        while true {
            if try applier.hasState(), try state("SELECT (applied_file='\(end.file)' AND applied_position='\(end.position)') OR (applied_sequence=0 AND baseline_gtids='\(end.gtids)') FROM state") == "1" { return }
            try require(try !applier.pids().isEmpty && Date() < deadline,"applier has not caught up")
            Thread.sleep(forTimeInterval:0.1)
        }
    }
    func fail() throws {
        try compare() // Save the exact completed boundary before inducing failure.
        try executeSQL(file: root.appendingPathComponent("examples/demo/02-failure.sql"))
        try verifyBlocked()
    }
    func verifyBlocked() throws {
        let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture!.output.appendingPathComponent("comparison.json"))) as? [String: Any]
        let deadline = Date().addingTimeInterval(25)
        while try !applier.pids().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        try require(applier.pids().isEmpty, "mysql-replicator did not stop on the failure SQL")
        try require(applier.containerState() == "running", "applier container should remain available after a replication failure")
        let diagnostic = try state("SELECT lifecycle||'|'||COALESCE(diagnostic,'') FROM state")
        try require(diagnostic.hasPrefix("BLOCKED|") && diagnostic.contains("explicit engine"), "unexpected Swift failure: " + diagnostic)
        try require(checkpoint() == previous?["checkpoint"] as? String, "Swift advanced its checkpoint past the last successful comparison")
        let h=fixture!.h
        let end = try fixture!.boundary()
        _ = try h.sql("native", "SELECT \(profile.nativeVersion.positionWait)('\(end.file)',\(end.position),5)")
        let native = try h.status()
        try require(native[profile.nativeVersion.sqlRunningField] == "No" && native["Last_SQL_Errno"] == "3161", "native did not reject explicit InnoDB with error 3161")
        var results: [String: [String: String]] = [:]
        for service in h.services {
            let table = try h.sql(service, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='explicit_innodb'")
            let marker = try h.sql(service, "SELECT COUNT(*) FROM demo.items WHERE id=999")
            try require(table == (service == "source" ? "1" : "0") && marker == (service == "source" ? "1" : "0"), "\(service) did not preserve the expected failure boundary")
            results[service] = ["failure_table": table, "following_marker": marker]
        }
        let previousObservations = previous?["observations"] as? [String: [String: String]]
        for service in ["native", "target57"] {
            try require(observation(service == "native" ? .native : .target) == previousObservations?[service], "\(service) changed data/schema after the last successful comparison")
        }
        try writeJSON(["result": "passed", "swift_diagnostic": diagnostic, "native": native, "checkpoint": try checkpoint(), "observations": results], to: fixture!.output.appendingPathComponent("failure.json"))
        print("PASS: native stopped with 3161; Swift is BLOCKED with an unchanged applied checkpoint. The failed table and following marker exist only on source.")
    }
}
