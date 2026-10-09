import Foundation

/// Named, dependency-ordered demo obligations. Session mechanics are shared with
/// the interactive command; version/engine-specific experiments stay explicit.
enum LabDemoQualification {
    struct Scenario {
        let test: QualificationCase
        let family: String
        var dependencies: [String] = []
        var profile: LabProfile? = nil
        var id: String { test.id }
        func fields(_ selectedProfile: LabProfile) -> [String:Any] {
            var row=test.fields
            row["profile"]=selectedProfile.rawValue; row["suite"]="demo"; row["family"]=family
            row["dependencies"]=dependencies; row["variant"]="default"
            row["status"]=profile == nil || profile == selectedProfile ? "not_run" : "not_applicable"
            if let profile, profile != selectedProfile { row["reason"]="This scenario qualifies "+profile.rawValue+" engine/version behavior." }
            return row
        }
    }
    static let scenarios: [Scenario] = [
        .init(test:.init("demo-prepared","Idle shell, pinned setup and safe repeated up"),family:"lifecycle"),
        .init(test:.init("demo-start-idle","Manual start and 35 seconds of idle heartbeats"),family:"lifecycle",dependencies:["demo-prepared"]),
        .init(test:.init("demo-success","Workbook database/table DDL and exact DML/schema/counters"),family:"workbook",dependencies:["demo-start-idle"]),
        .init(test:.init("demo-container-repair","Repair missing shell without resetting data or checkpoint"),family:"lifecycle"),
        .init(test:.init("demo-fail-stop","Explicit InnoDB DDL blocks MyISAM and native without advancing"),family:"failure",dependencies:["demo-success"],profile:.forward),
        .init(test:.init("demo-skip-and-resume","Exact DDL skip, refused broad skip, queued/fresh rows and repeat resume"),family:"failure",dependencies:["demo-fail-stop"],profile:.forward),
        .init(test:.init("demo-modify-index","Workbook MODIFY and indexes preserve rows after skip"),family:"workbook",dependencies:["demo-skip-and-resume"],profile:.forward),
        .init(test:.init("demo-idle-sigint","Idle SIGINT exits zero and preserves baseline checkpoint"),family:"resume"),
        .init(test:.init("demo-resume-baseline-gtid","Saved baseline overrides YAML; queued DDL/DML executes once"),family:"resume",dependencies:["demo-idle-sigint"]),
        .init(test:.init("demo-applied-sigterm","SIGTERM preserves the applied checkpoint and counters"),family:"resume"),
        .init(test:.init("demo-resume-applied-position","Saved file position overrides YAML; schema and counters survive repeated resume"),family:"resume",dependencies:["demo-applied-sigterm"],profile:.forward),
        .init(test:.init("demo-resume-applied-gtid","Saved applied GTIDs override YAML; schema and counters survive repeated resume"),family:"resume",dependencies:["demo-applied-sigterm"],profile:.reverse),
        .init(test:.init("demo-reverse-workbook","Reverse composite-PK transaction and repaired-shell resume"),family:"workbook",profile:.reverse),
        .init(test:.init("demo-reverse-recovery","Blocked status, transaction rollback, audited retry and following comparison"),family:"failure",dependencies:["demo-reverse-workbook"],profile:.reverse)
    ]
    static func select(family: String?, ids: Set<String>) throws -> [Scenario] {
        try require(ids.isSubset(of:Set(scenarios.map(\.id))),"unknown demo cases")
        if let family { try require(scenarios.contains { $0.family == family },"unknown demo family") }
        var selected=Set(scenarios.filter { (family == nil || $0.family == family) && (ids.isEmpty || ids.contains($0.id)) }.map(\.id))
        try require(ids.isEmpty || selected == ids,"demo cases do not belong to requested family")
        var prior: Set<String>=[]
        while prior != selected {
            prior=selected
            for item in scenarios where selected.contains(item.id) { selected.formUnion(item.dependencies) }
        }
        return scenarios.filter { selected.contains($0.id) }
    }
    final class Run {
        let root: URL, output: URL, profile: LabProfile, image: String, category: String, coverage: Bool
        let selected: Set<String>
        let reporter: QualificationReporter
        init(root: URL, profile: LabProfile, category: String, image: String, coverage: Bool, selected: Set<String>) throws {
            self.root=root; self.profile=profile; self.category=category; self.image=image; self.coverage=coverage; self.selected=selected
            output=root.appendingPathComponent("artifacts/"+category)
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            reporter=QualificationReporter(output:output,log:{ FileHandle.standardError.write(Data(($0+"\n").utf8)) })
        }
        func check(_ id: String, _ body: () throws -> Void) throws {
            if selected.contains(id) { try reporter.run(LabDemoQualification.scenarios.first { $0.id == id }!.test,body) }
        }
        func session(_ name: String, _ body: (LabDemo.Session) throws -> Void) throws {
            let session=LabDemo.Session(root:root,profile:profile,category:category+"/"+name)
            var failure: Error?
            do { try session.up(build:false,coverage:coverage,image:image); try body(session) }
            catch { failure=reporter.fail(error) }
            if session.fixture != nil {
                do { try session.down() } catch { if failure == nil { failure=error } }
            }
            if let failure { throw failure }
        }
        func execute() throws {
            var failure: Error?
            do {
                if selected.contains("demo-prepared") { try primary() }
                if selected.contains("demo-container-repair") { try repair() }
                for idle in [true,false] where selected.contains(idle ? "demo-idle-sigint" : "demo-applied-sigterm") { try detached(idle:idle) }
                if selected.contains("demo-reverse-workbook") { try reverseWorkbook() }
            } catch { failure=error }
            try writeJSON(["result":failure == nil ? "passed" : "failed","profile":profile.rawValue,"code_coverage":coverage,"image":image,"error":failure.map(String.init(describing:)) ?? "","cleanup":failure == nil ? "passed" : "inspect fixture evidence"],to:output.appendingPathComponent("result.json"))
            if let failure { throw failure }
        }
        func primary() throws {
            try session("workbook") { s in
                let f=s.fixture!
                try check("demo-prepared") {
                    try require(try s.lifecycle() == "NOT_STARTED" && s.applier.containerState() == "running","demo unexpectedly initialized state or lacks shell")
                    let before=f.image
                    try s.up(build:false)
                    try require(try s.lifecycle() == "NOT_STARTED" && s.fixture!.image == before,"repeated up changed state/image")
                    _ = try f.docker(["exec",s.applier.name,"/bin/bash","-c","test -r /evidence/apply.yaml && test -n \"$SOURCE_PASSWORD\" && test -n \"$TARGET_PASSWORD\" && mysql-replicator --version"])
                }
                try check("demo-start-idle") {
                    // Exercise the workbook's foreground command and inherited environment.
                    _ = try f.docker(["exec","-d",s.applier.name,"/bin/bash","-c","exec mysql-replicator run --config /evidence/apply.yaml --initialize"])
                    let deadline=Date().addingTimeInterval(30)
                    while try !s.applier.hasState() || s.lifecycle() != "RUNNING" {
                        try require(Date() < deadline,"manual applier did not start")
                        Thread.sleep(forTimeInterval:0.1)
                    }
                    var refused=false; do { try s.start() } catch { refused=true }
                    try require(refused,"duplicate start accepted")
                    Thread.sleep(forTimeInterval:35)
                    try require(try !s.applier.pids().isEmpty && s.lifecycle() == "RUNNING","idle applier stopped")
                }
                try check("demo-success") {
                    try s.executeSQL(file:root.appendingPathComponent("examples/demo/01-success.sql")); try s.compare()
                    try require(try s.state("SELECT transactions_applied||'|'||ddl_applied||'|'||rows_applied FROM state") == "8|3|6","workbook counters differ")
                    try require(try f.sql(.target,"SELECT id,value,quantity,IFNULL(note,'NULL') FROM demo.items ORDER BY id") == "1\tupdated\t11\tafter DDL\n3\tthird\t30\tNULL","workbook data differs")
                }
                if profile == .forward { try forwardFailure(s) }
            }
        }
        func repair() throws {
            try session("container-repair") { s in
                try check("demo-container-repair") {
                    let f=s.fixture!
                    let retained=try f.docker(["image","inspect",LabBuild.retainedTag(f.image),"--format","{{.Id}}"] ).text
                    try require(retained == f.image,"retained demo image lost its immutable tag")
                    try s.start()
                    _ = try f.sql(.source,"INSERT INTO reverse_poc.aux VALUES(1,7)")
                    try s.compare(); try s.stop()
                    try s.start()
                    _ = try f.sql(.source,"UPDATE reverse_poc.aux SET counter=8 WHERE id=1")
                    try s.compare(); try s.stop()
                    let checkpoint=try s.checkpoint()
                    _ = try f.docker(["rm","-f",s.applier.name])
                    try require(try s.applier.containerState() == "NOT_CREATED" && s.lifecycle() == "STOPPED","missing shell lost saved status")
                    try s.status(); try s.up(build:false); try s.start(); try s.compare(); try s.stop()
                    try require(try s.checkpoint() == checkpoint,"repair changed saved checkpoint")
                }
            }
        }
        func forwardFailure(_ session: LabDemo.Session) throws {
            try check("demo-fail-stop") {
                try session.fail(); try session.status()
                let before = try session.state("SELECT diagnostic FROM state")
                let refused = try session.cli(["run"],checked:false)
                try require(refused.status != 0 && String(decoding:refused.stderr,as:UTF8.self).contains("cleanly STOPPED"), "BLOCKED state was resumed")
                try require(session.state("SELECT diagnostic FROM state") == before, "resume refusal overwrote original diagnostic")
            }
            try check("demo-skip-and-resume") {
                let id=try session.state("SELECT active_gtid FROM state")
                let checkpoint=try session.state("SELECT applied_file||'|'||applied_position||'|'||transactions_applied FROM state")
                let refused=try session.cli(["skip",id + "-999999"],checked:false)
                try require(refused.status != 0 && String(decoding:refused.stderr,as:UTF8.self).contains("skip_failed"),"broader skip was accepted or lacked a diagnostic")
                try require(session.state("SELECT applied_file||'|'||applied_position||'|'||transactions_applied FROM state") == checkpoint,"refused skip changed checkpoint")
                let end=try session.state("SELECT source_file||'|'||end_position FROM groups WHERE status='PENDING'")
                let skipped=try session.cli(["skip",id])
                try skipped.stdout.write(to:session.fixture!.output.appendingPathComponent("skip.json"))
                let summary=try JSONSerialization.jsonObject(with:skipped.stdout) as? [String:Any]
                try require(summary?["skippedGTIDSet"] as? String == id && summary?["lifecycle"] as? String == "STOPPED","skip summary differs")
                try require(session.state("SELECT lifecycle||'|'||transactions_applied||'|'||ddl_applied||'|'||rows_applied||'|'||IFNULL(active_gtid,'NULL')||'|'||IFNULL(diagnostic,'NULL') FROM state") == "STOPPED|8|3|6|NULL|NULL","skip changed counters or left unresolved state")
                try require(session.state("SELECT applied_file||'|'||applied_position FROM state") == end,"skip did not advance to captured end")
                try session.start()
                try session.executeSQL(file:root.appendingPathComponent("examples/demo/03-after-skip.sql"))
                let boundary=try session.fixture!.h.boundary("source")
                let deadline=Date().addingTimeInterval(25)
                while try session.state("SELECT applied_file||'|'||applied_position FROM state") != boundary.file + "|" + String(boundary.position) {
                    try require(Date() < deadline && !session.applier.pids().isEmpty,"post-skip INSERT did not reach Swift checkpoint")
                    Thread.sleep(forTimeInterval:0.2)
                }
                let sql="SELECT id,value,quantity,note FROM demo.items WHERE id IN (999,1000) ORDER BY id"
                try require(session.fixture!.h.sql("target57",sql) == session.fixture!.h.sql("source",sql),"queued/fresh INSERT values differ after skip")
                try require(session.fixture!.h.sql("target57","SELECT COUNT(*) FROM demo.items WHERE id IN (999,1000)") == "2","post-skip rows missing")
                try require(session.fixture!.h.sql("target57","SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='explicit_innodb'") == "0","skip executed rejected CREATE")
                try require(session.fixture!.h.status()["Last_SQL_Errno"] == "3161" && session.fixture!.h.sql("native","SELECT COUNT(*) FROM demo.items WHERE id IN (999,1000)") == "0","skip changed native reference")
                try session.applier.drain(signal:"TERM"); try session.start(); try session.applier.drain(signal:"TERM")
                try require(session.state("SELECT lifecycle||'|'||transactions_applied||'|'||ddl_applied||'|'||rows_applied FROM state") == "STOPPED|10|3|8","resume replayed skipped/applied work or lost counters")
            }
            try check("demo-modify-index") {
                try session.start()
                try session.executeSQL(file:root.appendingPathComponent("examples/demo/04-modify-index.sql"))
                let boundary=try session.fixture!.h.boundary("source"), deadline=Date().addingTimeInterval(30)
                while try session.state("SELECT applied_file||'|'||applied_position FROM state") != boundary.file + "|" + String(boundary.position) {
                    try require(Date()<deadline && !session.applier.pids().isEmpty,"prepared MODIFY/index SQL did not reach checkpoint")
                    Thread.sleep(forTimeInterval:0.2)
                }
                let rows="SELECT id,HEX(value),quantity,IFNULL(HEX(note),'NULL') FROM demo.items ORDER BY id"
                let indexes="SELECT INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,IFNULL(SUB_PART,0),INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='items' ORDER BY INDEX_NAME,SEQ_IN_INDEX"
                try require(session.fixture!.h.sql("target57",rows)==session.fixture!.h.sql("source",rows),"prepared MODIFY/index rows differ")
                for service in ["source","target57"] {
                    try require(session.fixture!.h.sql(service,"SELECT CHARACTER_MAXIMUM_LENGTH,IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='items' AND COLUMN_NAME='value'")=="120\tNO","prepared MODIFY metadata differs")
                    try require(session.fixture!.h.sql(service,indexes)=="PRIMARY\t0\t1\tid\t0\tBTREE\nvalue_prefix\t1\t1\tvalue\t30\tBTREE\nvalue_prefix\t1\t2\tquantity\t0\tBTREE","prepared index metadata differs")
                    try require(session.fixture!.h.sql(service,"SELECT GROUP_CONCAT(id ORDER BY id) FROM demo.items")=="1,3,999,1000","prepared SQL lost retained rows or failed DELETE")
                }
                try session.applier.drain(signal:"TERM")
                try require(session.state("SELECT lifecycle||'|'||transactions_applied||'|'||ddl_applied||'|'||rows_applied FROM state")=="STOPPED|17|7|11","prepared MODIFY/index counters differ")
            }
        }
        func configureStart(_ s: LabDemo.Session, mode: String, boundary: Boundary) throws {
            let f=s.fixture!
            var source=f.config["source"] as! [String:Any]
            source["mode"]=mode
            source["start"]=(mode == "gtid" ? LabVariant.gtidFull : .positionMinimal).start(boundary)
            f.config["source"]=source; try f.installConfig()
        }
        func detached(idle: Bool) throws {
            try session(idle ? "idle-resume" : "position-resume") { s in
                let f=s.fixture!, id=idle ? "demo-idle-sigint" : "demo-applied-sigterm"
                let mode=idle || profile == .reverse ? "gtid" : "file-position"
                let resumeID=idle ? "demo-resume-baseline-gtid" : (profile == .reverse ? "demo-resume-applied-gtid" : "demo-resume-applied-position")
                try check(id) {
                    try configureStart(s,mode:mode,boundary:f.boundary())
                    try s.start()
                    if !idle { try s.executeSQL(file:root.appendingPathComponent("examples/demo/01-success.sql")); try s.compare() }
                    let query="SELECT baseline_gtids||'|'||IFNULL(applied_file,'NULL')||'|'||IFNULL(applied_position,'NULL')||'|'||applied_sequence FROM state"
                    let checkpoint=try s.state(query)
                    try s.applier.drain(signal:idle ? "INT" : "TERM")
                    try require(try s.applier.containerState() == "running","signal killed shell")
                    try require(try s.state("SELECT lifecycle||'|'||transactions_applied||'|'||ddl_applied||'|'||rows_applied||'|'||IFNULL(active_gtid,'NULL')||'|'||IFNULL(diagnostic,'NULL') FROM state") == (idle ? "STOPPED|0|0|0|NULL|NULL" : "STOPPED|8|3|6|NULL|NULL"),"signal lost progress or diagnostic")
                    try require(try s.state(query) == checkpoint,"signal changed checkpoint")
                    let deadline=Date().addingTimeInterval(5)
                    while try f.docker(["exec",s.applier.name,"test","-f","/evidence/applier.exit"],checked:false).status != 0 && Date() < deadline { Thread.sleep(forTimeInterval:0.1) }
                    try require(try f.docker(["exec",s.applier.name,"cat","/evidence/applier.exit"]).text == "0","signal exit was not successful")
                    let final=try s.applier.logs().stderr
                    let summary=try JSONSerialization.jsonObject(with:final) as? [String:Any]
                    try require(summary?["lifecycle"] as? String == "STOPPED" && summary?["error"] == nil,"signal lacks successful summary")
                }
                try check(resumeID) {
                    let refused=try s.cli(["run","--initialize"],checked:false)
                    try require(refused.status != 0 && String(decoding:refused.stderr,as:UTF8.self).contains("must be new"),"initialize overwrote saved state")
                    if idle { try s.executeSQL(file:root.appendingPathComponent("examples/demo/01-success.sql")) }
                    else { _ = try f.sql(.source,"ALTER TABLE demo.items ADD COLUMN resumed INT NULL; UPDATE demo.items SET quantity=12,resumed=7 WHERE id=1; INSERT INTO demo.items VALUES(4,'after resume',40,'queued',9); DELETE FROM demo.items WHERE id=3") }
                    try configureStart(s,mode:mode,boundary:f.boundary())
                    try s.start(); try s.compare()
                    let expected=idle ? "8|3|6" : "12|4|9"
                    try require(try s.state("SELECT transactions_applied||'|'||ddl_applied||'|'||rows_applied FROM state") == expected,"resume skipped or replayed rows")
                    if !idle { try require(try f.sql(.target,"SELECT id,resumed FROM demo.items ORDER BY id") == "1\t7\n4\t9","resumed DDL values differ") }
                    let duplicate=try s.cli(["run"],checked:false)
                    try require(duplicate.status != 0 && String(decoding:duplicate.stderr,as:UTF8.self).contains("active writer"),"concurrent writer was not refused")
                    try s.stop(); try s.start(); try s.compare(); try s.stop()
                    try require(try s.state("SELECT lifecycle||'|'||transactions_applied||'|'||ddl_applied||'|'||rows_applied FROM state") == "STOPPED|"+expected,"repeated resume lost state")
                }
            }
        }
        func reverseWorkbook() throws {
            try session("reverse-workbook") { s in
                let f=s.fixture!
                try check("demo-reverse-workbook") {
                    try s.start(); try s.executeSQL(file:root.appendingPathComponent("examples/reverse-demo/01-success.sql"))
                    try s.compare(); try s.stop()
                    let inspection=try s.cli(["recovery","inspect"])
                    try inspection.stdout.write(to:f.output.appendingPathComponent("stopped.json"))
                    let clean=try JSONSerialization.jsonObject(with:inspection.stdout) as? [String:Any]
                    try require(clean?["lifecycle"] as? String == "STOPPED","clean inspection lost saved status")
                    guard let gtids=clean?["appliedGTIDSet"] as? String else { throw LabError("clean inspection omitted applied GTIDs") }
                    let boundary=try f.boundary()
                    try require(try f.sql(.source,"SELECT GTID_SUBSET('\(boundary.gtids)','\(gtids)')") == "1","clean inspection does not cover source")
                    let checkpoint=try s.checkpoint()
                    _ = try f.docker(["rm","-f",s.applier.name])
                    try require(try s.applier.containerState() == "NOT_CREATED" && s.lifecycle() == "STOPPED","missing container lost status")
                    try s.status(); try s.up(build:false)
                    try require(try s.checkpoint() == checkpoint,"repair reset state")
                    try s.start(); try s.executeSQL(file:root.appendingPathComponent("examples/reverse-demo/02-after-resume.sql"))
                    try s.compare(); try s.stop()
                }
                try check("demo-reverse-recovery") {
                    _ = try f.sql(.target,"INSERT INTO reverse_poc.aux VALUES(99,99)")
                    _ = try f.sql(.source,"START TRANSACTION; UPDATE reverse_poc.items SET value='recovered' WHERE id=2; INSERT INTO reverse_poc.aux VALUES(99,99); COMMIT")
                    try s.applier.start(initialize:false)
                    let deadline=Date().addingTimeInterval(30)
                    while try !s.applier.pids().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval:0.2) }
                    try require(try s.applier.pids().isEmpty && s.lifecycle() == "BLOCKED" && s.applier.containerState() == "running","failure did not preserve BLOCKED shell")
                    try s.status()
                    let inspection=try s.cli(["recovery","inspect"])
                    try inspection.stdout.write(to:f.output.appendingPathComponent("blocked.json"))
                    guard let report=try JSONSerialization.jsonObject(with:inspection.stdout) as? [String:Any],
                          let pending=report["pending"] as? [[String:Any]], let gtid=pending.first?["gtid"] as? String else { throw LabError("missing pending recovery GTID") }
                    try require(try f.sql(.target,"SELECT value FROM reverse_poc.items WHERE id=2") != "recovered","failed transaction did not roll back")
                    _ = try f.sql(.target,"DELETE FROM reverse_poc.aux WHERE id=99")
                    let resolved=try s.cli(["recovery","resolve","retry","--gtids",gtid,"--reason","demo removed target-only conflict after rollback"])
                    try resolved.stdout.write(to:f.output.appendingPathComponent("retry.json"))
                    try s.start(); try s.compare(); try s.stop()
                    let final=try s.cli(["recovery","inspect"])
                    try final.stdout.write(to:f.output.appendingPathComponent("recovered.json"))
                    let recovered=try JSONSerialization.jsonObject(with:final.stdout) as? [String:Any]
                    let audit=recovered?["audit"] as? [[String:Any]]
                    try require(recovered?["lifecycle"] as? String == "STOPPED" && (recovered?["pending"] as? [[String:Any]])?.isEmpty == true,"recovery left pending work")
                    try require(audit?.count == 1 && audit?.first?["action"] as? String == "retry" && audit?.first?["gtids"] as? String == gtid && audit?.first?["reason"] as? String == "demo removed target-only conflict after rollback","recovery lost its audit record")
                }
            }
        }
    }
}
