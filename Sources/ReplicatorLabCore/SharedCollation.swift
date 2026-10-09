import Foundation

extension SharedCorrectness.Run {
    /// These mappings are specific to an 8.4 source and 5.7 target. The reverse
    /// profile must not claim that a 5.7 source exercised 0900/NO PAD semantics.
    func collationWorkflows() throws {
        guard f.profile == .forward,
              selects(DDLCompatibilityCases.collationCleanup.id) || selects(DDLCompatibilityCases.collationCollision.id) else { return }
        try resetNativeEngine()
        let isolated=LabIsolatedApply(f)
        var configurations: [String:[String:Any]] = [:]
        func resetCompatibility() throws {
            // Drain native before reseeding. After collision there is no replay:
            // a later experiment gets an independent durable baseline.
            _ = try f.sql(.native,"START REPLICA")
            try f.awaitNative()
            _ = try f.sql(.native,"STOP REPLICA")
            for role in LabProfile.Role.allCases {
                _ = try f.sql(role,"SET sql_log_bin=0; DROP DATABASE IF EXISTS ddlcompat; CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
            }
        }
        func configuration(_ label: String, at boundary: Boundary, count: Int) -> [String:Any] {
            isolated.configuration(label,at:boundary,count:count)
        }
        func start(_ test: QualificationCase, _ config: [String:Any], initialize: Bool = true) throws -> String {
            try reporter.begin(test)
            configurations[test.id]=config
            return try isolated.start(test.id,config:config,initialize:initialize)
        }
        func finish(_ client: String, _ label: String, reason: String? = nil) throws -> [String:Any] {
            try isolated.finish(client,label:label,config:configurations[label]!,reason:reason)
        }
        func state(_ label: String, _ sql: String) throws -> String { try isolated.state(label,sql) }
        if selects(DDLCompatibilityCases.collationCleanup.id) {
            try resetCompatibility()
            for service in LabProfile.Role.allCases { _ = try f.sql(service,"SET SESSION sql_log_bin=0; DROP DATABASE ddlcompat") }
            let test = DDLCompatibilityCases.collationCleanup, label = test.id
            let mapping = ["collations":["utf8mb4_0900_ai_ci":"utf8mb4_unicode_ci"]]
            let logged = "SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci; SET SESSION collation_server=utf8mb4_0900_ai_ci; SET SESSION default_collation_for_utf8mb4=utf8mb4_0900_ai_ci; "
            var config = configuration(label,at:try f.boundary(),count:9)
            config["compatibility"] = mapping
            let initialTest = DDLCompatibilityCases.collationCleanupInitial
            let initial = try start(initialTest,config)
            _ = try f.sql(.native,"START REPLICA")
            _ = try f.sql(.source,logged+"""
            CREATE DATABASE ddlcompat;
            CREATE TABLE ddlcompat.foo(id INT PRIMARY KEY,v VARCHAR(80));
            INSERT INTO ddlcompat.foo VALUES(1,'keep'),(2,'drop'),(3,CONVERT(0xC3A9F09F9880 USING utf8mb4));
            CREATE TABLE ddlcompat.foo_temp LIKE ddlcompat.foo;
            INSERT INTO ddlcompat.foo_temp SELECT * FROM ddlcompat.foo WHERE id<>2;
            ALTER TABLE ddlcompat.foo_temp ADD extra VARCHAR(40) CHARACTER SET utf8mb4 DEFAULT 'utf8mb4_0900_ai_ci';
            RENAME TABLE ddlcompat.foo TO ddlcompat.foo_old, ddlcompat.foo_temp TO ddlcompat.foo;
            CREATE TABLE ddlcompat.explicit_table(id INT PRIMARY KEY,v VARCHAR(40) COLLATE utf8mb4_0900_ai_ci) CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
            CREATE TABLE ddlcompat.charset_only(id INT PRIMARY KEY,v VARCHAR(40)) DEFAULT CHARSET=utf8mb4;
            """)
            _ = try finish(initial,initialTest.id)
            try f.awaitNative()
            try reporter.pass(initialTest.id)
            // Changing a durable mapping must fail before any target SQL.
            for (rejectedTest,policy) in [(DDLCompatibilityCases.collationCleanupChanged,["collations":["utf8mb4_0900_ai_ci":"utf8mb4_bin"]]),(DDLCompatibilityCases.collationCleanupRemoved,["collations":[:]])] {
                var changed = config; changed["compatibility"] = policy
                let rejected = try start(rejectedTest,changed,initialize:false)
                _ = try finish(rejected,rejectedTest.id,reason:"differs from saved state")
                try reporter.pass(rejectedTest.id)
            }
            // Use saved schemas after restart, including the replacement
            // table's extra column and the old name's original schema.
            var capture = config["source"] as! [String:Any]
            capture["stopAfterTransactions"] = 7; config["source"] = capture
            let resumed = try start(test,config,initialize:false)
            _ = try f.sql(.source,logged+"""
            UPDATE ddlcompat.foo SET v='resumed',extra='new' WHERE id=1;
            INSERT INTO ddlcompat.explicit_table VALUES(1,CONVERT(0xC3A9F09F9880 USING utf8mb4));
            INSERT INTO ddlcompat.charset_only VALUES(1,'bytes');
            CREATE TABLE ddlcompat.foo_temp LIKE ddlcompat.foo;
            INSERT INTO ddlcompat.foo_temp SELECT * FROM ddlcompat.foo WHERE id=1;
            RENAME TABLE ddlcompat.foo TO ddlcompat.spare, ddlcompat.foo_temp TO ddlcompat.foo, ddlcompat.spare TO ddlcompat.foo_temp;
            INSERT INTO ddlcompat.foo VALUES(4,'after-swap','four');
            """)
            let result = try finish(resumed,label)
            try f.awaitNative(); _ = try f.sql(.native,"STOP REPLICA")
            for (query,expected) in [
                ("SELECT id,v,extra FROM ddlcompat.foo ORDER BY id","1\tresumed\tnew\n4\tafter-swap\tfour"),
                ("SELECT id,HEX(v) FROM ddlcompat.foo_temp ORDER BY id","1\t726573756D6564\n3\tC3A9F09F9880"),
                ("SELECT COUNT(*) FROM ddlcompat.foo_old","3"),
                ("SELECT HEX(v) FROM ddlcompat.explicit_table","C3A9F09F9880"),
                ("SELECT v FROM ddlcompat.charset_only","bytes")
            ] {
                for service in LabProfile.Role.allCases {
                    let actual = try f.sql(service,query)
                    try require(actual == expected,"collation cleanup row mismatch: \(service) \(query): \(actual), expected \(expected)")
                }
            }
            for service in LabProfile.Role.allCases {
                let collation = service == .target ? "utf8mb4_unicode_ci" : "utf8mb4_0900_ai_ci"
                try require(f.sql(service,"SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='ddlcompat'") == collation,"mapped database default differs")
                try require(f.sql(service,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ddlcompat' AND TABLE_COLLATION<>'\(collation)'") == "0","mapped table default differs")
                try require(f.sql(service,"SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='ddlcompat' AND COLLATION_NAME IS NOT NULL AND COLLATION_NAME<>'\(collation)'") == "0","mapped column encoding differs")
            }
            try require(result["transactionsApplied"] as? Int == 16 && result["ddlApplied"] as? Int == 9,"mapped cleanup counters differ")
            try require(state(label,"SELECT COUNT(*) FROM schemas WHERE current=1") == "5","rename left stale schemas")
            try require(state(label,"SELECT COUNT(*) FROM ddl_details JOIN ddl_intents USING(gtid) WHERE status='DONE'") == "9","mapped DDL audit missing")
            try require(state(label,"SELECT COUNT(*) FROM ddl_details JOIN ddl_intents USING(gtid) WHERE source_sql<>target_sql") == "3","encoding rewrite audit differs")
            try require(state(label,"SELECT COUNT(*) FROM ddl_details WHERE json_extract(policy_json,'$.collations.utf8mb4_0900_ai_ci')='utf8mb4_unicode_ci'") == "9","mapping policy missing from audit")
            try reporter.pass(label)
        }
        if selects(DDLCompatibilityCases.collationCollision.id) {
            try resetCompatibility()
            let test = DDLCompatibilityCases.collationCollision, label = test.id
            var config = configuration(label,at:try f.boundary(),count:5)
            config["compatibility"] = ["collations":["utf8mb4_0900_ai_ci":"utf8mb4_unicode_ci"]]
            let client = try start(test,config)
            _ = try f.sql(.native,"START REPLICA")
            _ = try f.sql(.source,"SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci; CREATE TABLE ddlcompat.collision(id INT PRIMARY KEY,v VARCHAR(20),UNIQUE KEY value_key(v)) CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci; INSERT INTO ddlcompat.collision VALUES(1,'a')")
            try isolated.barrier(client,count:2)
            let prefix = try f.boundary()
            _ = try f.sql(.source,"INSERT INTO ddlcompat.collision VALUES(2,'a '); INSERT INTO ddlcompat.collision VALUES(3,'must-not-apply')")
            let failure = try finish(client,label,reason:"1062")
            try f.awaitNative(); _ = try f.sql(.native,"STOP REPLICA")
            try require(f.sql(.target,"SELECT id,HEX(v) FROM ddlcompat.collision") == "1\t61","unique collision was ignored or changed rows")
            for service in [LabProfile.Role.source,.native] { try require(f.sql(service,"SELECT COUNT(*) FROM ddlcompat.collision") == "3","NO PAD source/native fixture did not accept both keys") }
            try require(state(label,"SELECT lifecycle||'|'||transactions_applied FROM state") == "BLOCKED|2","collision advanced the checkpoint")
            let progress = failure["progress"] as? [String:Any]
            try require(progress?["appliedGTIDSet"] as? String == prefix.gtids,"collision GTID was acknowledged")
            try require(state(label,"SELECT COUNT(*) FROM row_intents WHERE status='PENDING'") != "0","collision lost pending row intent")
            try reporter.pass(label)
        }
        _ = try f.sql(.native,"START REPLICA")
        try f.awaitNative()
    }
}
