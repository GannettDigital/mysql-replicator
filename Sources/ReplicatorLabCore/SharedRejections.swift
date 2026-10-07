import Foundation

extension SharedCorrectness.Run {
    /// Each refusal gets a fresh baseline/state on disposable fixtures. Never
    /// bypass a rejected GTID in a production state or turn it into a pass.
    func rejections() throws {
        let cases: [(String,String,String)] = [
            ("enum-non-bmp","CREATE TABLE rejected.bad(id INT PRIMARY KEY,n ENUM('🙂')) CHARACTER SET utf8mb4","supplementary-plane labels"),
            ("set-non-bmp","CREATE TABLE rejected.bad(id INT PRIMARY KEY,n SET('🙂')) CHARACTER SET utf8mb4","supplementary-plane labels"),
            ("engine","CREATE TABLE rejected.bad(id INT PRIMARY KEY) ENGINE="+(f.profile == .reverse ? "MyISAM" : "InnoDB"),"outside the "+f.profile.targetEngine+" DDL contract"),
            ("foreign-key","CREATE TABLE rejected.bad(id INT PRIMARY KEY,n INT,FOREIGN KEY(n) REFERENCES rejected.parent(id)) ENGINE=InnoDB","unsupported"),
            ("event","CREATE EVENT rejected.e ON SCHEDULE EVERY 1 DAY DISABLE DO INSERT INTO rejected.parent VALUES(99,99)","DDL policy rejects events"),
            ("trigger","CREATE TRIGGER rejected.tr BEFORE INSERT ON rejected.parent FOR EACH ROW SET NEW.n=7","DDL policy rejects triggers"),
            ("float","CREATE TABLE rejected.bad(id INT PRIMARY KEY,n FLOAT)","unsupported"),
            ("json","CREATE TABLE rejected.bad(id INT PRIMARY KEY,n JSON)","unsupported")
        ]
        let original=f.config
        defer { f.config=original }
        for (id,sql,reason) in cases where selects("reject-"+id) {
            let label="reject-"+id
            try reporter.run(QualificationCase(label,"DDL rejection: "+id)) {
                // Equivalent bootstrap, deliberately outside the tested stream.
                for role in LabProfile.Role.allCases {
                    let engine=role == .native && id == "foreign-key" ? "InnoDB" : f.profile.engine(role)
                    _ = try f.sql(role,"SET sql_log_bin=0; DROP DATABASE IF EXISTS rejected; CREATE DATABASE rejected CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE rejected.parent(id INT PRIMARY KEY,n INT) ENGINE="+engine)
                }
                let before=try f.boundary()
                f.config=original; f.config["stateDirectory"]="/evidence/"+label
                f.config["ddlPolicy"]=["triggers":"reject","events":"reject"]
                var source=f.config["source"] as! [String:Any]
                source["start"]=["file":before.file,"position":before.position,"executedGTIDs":before.gtids]
                source["stopAfterTransactions"]=2; f.config["source"]=source
                try f.installConfig(label)
                _ = try f.sql(.source,session+sql+"; INSERT INTO rejected.parent VALUES(1,1)")
                let client=try f.startClient(label,arguments:["run","--config","/evidence/"+label+".yaml","--initialize"])
                let exit=try f.runner.run(["docker","wait",client],timeout:90).text
                let logs=try f.docker(["logs",client])
                try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
                try require(exit != "0","unsupported DDL was accepted")
                guard let line=logs.stderr.split(separator:10).last,
                      let diagnostic=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any],
                      let progress=diagnostic["progress"] as? [String:Any],
                      let failure=progress["targetFailure"] as? [String:Any],
                      let trace=failure["statement"] as? [String:Any] else { throw LabError("missing rejection diagnostic") }
                try require((diagnostic["reason"] as? String ?? "").contains(reason),"wrong rejection: \(diagnostic)")
                try require(progress["appliedGTIDSet"] as? String == before.gtids && progress["transactionsApplied"] as? Int == 0 && trace["phase"] as? String == "notIssued","rejection advanced checkpoint or issued target DDL")
                try require(try f.sql(.target,"SELECT COUNT(*) FROM rejected.parent") == "0","following DML escaped rejection")
                try require(try f.sql(.target,"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='rejected' AND TABLE_NAME='bad'") == "0","rejected table was created")
                try require(try f.sql(.target,"SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='rejected'; SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='rejected'") == "0\n0","rejected event/trigger was installed")
                try f.awaitNative()
                try require(try f.h.sql("native","SELECT COUNT(*) FROM rejected.parent") == "1","native reference failed source-accepted DDL/DML")
                _ = try f.docker(["cp",f.helper+":/evidence/"+label,f.output.path])
                let evidence=try f.runner.run(["sqlite3",f.output.appendingPathComponent(label+"/state.sqlite").path,"SELECT lifecycle,transactions_applied,active_gtid,diagnostic FROM state"]).text
                try require(evidence.hasPrefix("BLOCKED|0|"),"missing durable rejection evidence")
                try writeJSON(["source_before":before.json,"diagnostic":diagnostic,"durable_state":evidence],to:f.output.appendingPathComponent(label+".json"))
            }
        }
    }
}
