import Foundation

extension SharedCorrectness.Run {
    func foreignKeys() throws {
        guard f.profile.transactionalTarget && selects("foreign-keys") else { return }
        try reporter.run(QualificationCase("foreign-keys","InnoDB foreign-key DDL, cascades, composite keys and saved-state restart")) {
            let db = "fk_poc"
            try step("CREATE DATABASE \(db) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",database:db)
            let definitions = [
                "parent(id INT PRIMARY KEY, code INT NOT NULL, UNIQUE KEY code(code))",
                "child(id INT PRIMARY KEY,pid INT, FOREIGN KEY(pid) REFERENCES fk_poc.parent(id) ON DELETE CASCADE ON UPDATE CASCADE)",
                "grandchild(id INT PRIMARY KEY,cid INT, CONSTRAINT grand_fk FOREIGN KEY(cid) REFERENCES fk_poc.child(id) ON DELETE CASCADE ON UPDATE CASCADE)",
                "nullable_child(id INT PRIMARY KEY,pid INT, CONSTRAINT null_fk FOREIGN KEY(pid) REFERENCES fk_poc.parent(id) ON DELETE SET NULL ON UPDATE SET NULL)",
                "restricted(id INT PRIMARY KEY,pid INT, CONSTRAINT restrict_fk FOREIGN KEY(pid) REFERENCES fk_poc.parent(code) ON DELETE RESTRICT ON UPDATE NO ACTION)",
                "composite_parent(report_date DATE,id INT, PRIMARY KEY(report_date,id))",
                "composite_child(id INT PRIMARY KEY,report_date DATE,pid INT, CONSTRAINT composite_fk FOREIGN KEY(report_date,pid) REFERENCES fk_poc.composite_parent(report_date,id) ON DELETE CASCADE ON UPDATE CASCADE)"
            ]
            for definition in definitions { try step("CREATE TABLE \(db).\(definition) ENGINE=InnoDB",database:db) }
            try step("BEGIN; INSERT INTO fk_poc.parent VALUES(1,101),(2,102),(3,103); INSERT INTO fk_poc.child VALUES(11,1),(12,2),(13,3); INSERT INTO fk_poc.grandchild VALUES(111,11),(112,12); INSERT INTO fk_poc.nullable_child VALUES(21,1),(22,2); INSERT INTO fk_poc.restricted VALUES(31,101); COMMIT",database:db)
            // A failed source statement emits no committed row changes.
            var rejected = false
            do { _ = try f.sql(.source,session+"DELETE FROM fk_poc.parent WHERE id=1") } catch { rejected = String(describing:error).contains("1451") }
            try require(rejected,"source RESTRICT did not reject the parent delete")
            _ = try compare(db)
            try step("DELETE FROM fk_poc.restricted WHERE id=31",database:db)
            try step("UPDATE fk_poc.parent SET id=10 WHERE id=1",database:db,checks:[.init("SELECT pid FROM fk_poc.child WHERE id=11","10"),.init("SELECT pid IS NULL FROM fk_poc.nullable_child WHERE id=21","1")])
            try step("UPDATE fk_poc.child SET id=110 WHERE id=11",database:db,checks:[.init("SELECT cid FROM fk_poc.grandchild WHERE id=111","110")])
            try step("DELETE FROM fk_poc.parent WHERE id=10",database:db,checks:[.init("SELECT COUNT(*) FROM fk_poc.grandchild WHERE id=111","0")])
            try step("BEGIN; INSERT INTO fk_poc.composite_parent VALUES('2026-10-10',1); INSERT INTO fk_poc.composite_child VALUES(1,'2026-10-10',1); COMMIT",database:db)
            try step("UPDATE fk_poc.composite_parent SET report_date='2026-10-11',id=2",database:db,checks:[.init("SELECT pid FROM fk_poc.composite_child","2")])
            try step("BEGIN; DELETE FROM fk_poc.parent; ROLLBACK",database:db)
            try applier.drain(); try applier.start(initialize:false)
            try step("DELETE FROM fk_poc.parent WHERE id=2",database:db,checks:[.init("SELECT COUNT(*) FROM fk_poc.grandchild","0"),.init("SELECT COUNT(*) FROM fk_poc.nullable_child WHERE pid IS NULL","2")])
            try step("RENAME TABLE fk_poc.parent TO fk_poc.parent_new, fk_poc.child TO fk_poc.child_new",database:db)
            try step("INSERT INTO fk_poc.parent_new VALUES(4,104),(5,105)",database:db)
            try step("INSERT INTO fk_poc.child_new VALUES(14,4),(15,5)",database:db)
            try step("CREATE TABLE fk_poc.cloned LIKE fk_poc.child_new",database:db)
            try step("ALTER TABLE fk_poc.child_new DROP FOREIGN KEY child_new_ibfk_1",database:db)
            try step("ALTER TABLE fk_poc.child_new ADD CONSTRAINT restored_fk FOREIGN KEY(pid) REFERENCES fk_poc.parent_new(id) ON DELETE CASCADE ON UPDATE CASCADE",database:db)
            try step("DELETE FROM fk_poc.parent_new WHERE id IN (3,4,5)",database:db,checks:[.init("SELECT COUNT(*) FROM fk_poc.child_new","0")])
            try step("DELETE FROM fk_poc.composite_parent",database:db,checks:[.init("SELECT COUNT(*) FROM fk_poc.composite_child","0")])
            // Remove dependencies in child-to-parent order, with metadata checks
            // after every boundary and no foreign_key_checks=0 escape hatch.
            for name in ["grandchild","nullable_child","restricted","cloned","child_new","parent_new","composite_child","composite_parent"] { try step("DROP TABLE fk_poc.\(name)",database:db) }
            try step("DROP DATABASE fk_poc",database:db)
        }
    }
}

extension SharedCorrectness.Run {
    func foreignKeySafety() throws {
        guard f.profile.transactionalTarget && selects("foreign-key-safety") else { return }
        try reporter.run(QualificationCase("foreign-key-safety","Foreign-key exclusions, target rollback and offline cascade evidence")) {
            let original = f.config
            defer { f.config = original }
            let cases = [
                ("nonunique","CREATE TABLE fk_failure.bad(id INT PRIMARY KEY,pid INT,CONSTRAINT bad_fk FOREIGN KEY(pid) REFERENCES fk_failure.parent(n)) ENGINE=InnoDB","complete unique parent key"),
                ("filtered-ddl","CREATE TABLE fk_failure.bad(id INT PRIMARY KEY,pid INT,CONSTRAINT bad_fk FOREIGN KEY(pid) REFERENCES fk_failure.parent(id)) ENGINE=InnoDB","crosses included and excluded"),
                ("filtered-discovery","DELETE FROM fk_failure.parent WHERE id=1","crosses an excluded table"),
                ("rollback","BEGIN; INSERT INTO fk_failure.parent VALUES(2,2); INSERT INTO fk_failure.child VALUES(20,1); COMMIT","1452"),
                ("autocommit","INSERT INTO fk_failure.child VALUES(20,1)","1452"),
                ("checks-disabled-ddl","SET foreign_key_checks=0; CREATE TABLE fk_failure.bad(id INT PRIMARY KEY,pid INT,CONSTRAINT bad_fk FOREIGN KEY(pid) REFERENCES fk_failure.parent(id)) ENGINE=InnoDB","foreign_key_checks=0 is unsupported"),
                ("checks-disabled-rows","SET foreign_key_checks=0; INSERT INTO fk_failure.child VALUES(20,999)","row flags other than STMT_END")
            ]
            for (id,sql,reason) in cases {
                let label = "fk-"+id
                for role in LabProfile.Role.allCases {
                    _ = try f.sql(role,"SET sql_log_bin=0; DROP DATABASE IF EXISTS fk_failure; CREATE DATABASE fk_failure CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE fk_failure.parent(id INT PRIMARY KEY,n INT,KEY(n)) ENGINE=InnoDB; CREATE TABLE fk_failure.child(id INT PRIMARY KEY,pid INT,CONSTRAINT child_fk FOREIGN KEY(pid) REFERENCES fk_failure.parent(id) ON DELETE CASCADE) ENGINE=InnoDB; INSERT INTO fk_failure.parent VALUES(1,1)")
                }
                if id == "rollback" || id == "autocommit" { _ = try f.sql(.target,"SET sql_log_bin=0; DELETE FROM fk_failure.parent WHERE id=1") }
                let before = try f.boundary()
                f.config = original; f.config["stateDirectory"] = "/evidence/"+label
                if id == "filtered-ddl" { f.config["replicateWildIgnoreTable"] = ["fk_failure.bad"] }
                if id == "filtered-discovery" { f.config["replicateWildIgnoreTable"] = ["fk_failure.child"] }
                var source = f.config["source"] as! [String:Any]
                source["start"] = f.variant.start(before); source["stopAfterTransactions"] = 1; f.config["source"] = source
                try f.installConfig(label)
                _ = try f.sql(.source,session+sql)
                let client = try f.startClient(label,arguments:["run","--config","/evidence/"+label+".yaml","--initialize"])
                let exit = try f.runner.run(["docker","wait",client],timeout:90).text
                let logs = try f.docker(["logs",client])
                try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
                try require(exit != "0" && String(decoding:logs.stderr,as:UTF8.self).contains(reason),"foreign-key safety case did not fail as expected: "+label+" "+String(decoding:logs.stderr,as:UTF8.self))
                try f.awaitNative()
                _ = try f.docker(["cp",f.helper+":/evidence/"+label,f.output.path])
                let state = f.output.appendingPathComponent(label+"/state.sqlite").path
                let counts = try f.runner.run(["sqlite3",state,"SELECT transactions_applied FROM state"]).text
                try require(counts == "0","foreign-key failure advanced progress")
                try require(try f.sql(.target,"SELECT COUNT(*) FROM fk_failure.parent WHERE id=2; SELECT COUNT(*) FROM fk_failure.child") == "0\n0","failed transaction retained target changes")
                if id == "rollback" || id == "autocommit" {
                    let report = try f.docker(["run","--rm","--platform","linux/amd64","--network","none","--mount","type=volume,src=\(f.volume),dst=/evidence","--entrypoint","/usr/local/bin/mysql-replicator",f.image,"recovery","inspect","--config","/evidence/"+label+".yaml"])
                    try report.stdout.write(to:f.output.appendingPathComponent(label+"-recovery.json"))
                    guard let json = try JSONSerialization.jsonObject(with:report.stdout) as? [String:Any], let pending = json["pending"] as? [[String:Any]], let relations = pending.first?["foreignKeyRelationships"] as? [[String:Any]] else { throw LabError("missing recovery relationships") }
                    try require(relations.contains { $0["name"] as? String == "child_fk" && $0["onDelete"] as? String == "CASCADE" },"recovery lost cascade relationship")
                }
            }
            // Save a valid component, then alter only the target's constraint.
            // Resume must compare relationship history before issuing any write.
            for role in LabProfile.Role.allCases {
                _ = try f.sql(role,"SET sql_log_bin=0; DROP DATABASE IF EXISTS fk_failure; CREATE DATABASE fk_failure CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE fk_failure.parent(id INT PRIMARY KEY) ENGINE=InnoDB; CREATE TABLE fk_failure.child(id INT PRIMARY KEY,pid INT,CONSTRAINT child_fk FOREIGN KEY(pid) REFERENCES fk_failure.parent(id) ON DELETE CASCADE) ENGINE=InnoDB")
            }
            let baseline = try f.boundary(), label = "fk-history"
            f.config = original; f.config["stateDirectory"] = "/evidence/"+label
            var source = f.config["source"] as! [String:Any]
            source["start"] = f.variant.start(baseline); source["stopAfterTransactions"] = 1; f.config["source"] = source
            try f.installConfig(label)
            _ = try f.sql(.source,session+"INSERT INTO fk_failure.parent VALUES(1)")
            let first = try f.startClient(label,arguments:["run","--config","/evidence/"+label+".yaml","--initialize"])
            try require(try f.runner.run(["docker","wait",first],timeout:90).text == "0","foreign-key bootstrap failed")
            try f.awaitNative()
            _ = try f.sql(.target,"SET sql_log_bin=0; ALTER TABLE fk_failure.child DROP FOREIGN KEY child_fk")
            _ = try f.sql(.source,session+"INSERT INTO fk_failure.parent VALUES(2)")
            let resumed = try f.startClient(label+"-resume",arguments:["run","--config","/evidence/"+label+".yaml"])
            try require(try f.runner.run(["docker","wait",resumed],timeout:90).text != "0","resume accepted foreign-key drift")
            let logs = try f.docker(["logs",resumed])
            try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+"-resume.ndjson"))
            try require(String(decoding:logs.stderr,as:UTF8.self).contains("target schema differs from saved checkpoint"),"resume missed historical relationship mismatch")
            try require(try f.sql(.target,"SELECT COUNT(*) FROM fk_failure.parent WHERE id=2") == "0","write escaped historical schema validation")
            try f.awaitNative()
        }
    }
}
