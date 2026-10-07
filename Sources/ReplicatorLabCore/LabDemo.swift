import Foundation

/// Profile-specific retained sessions never attach to the legacy demo directories.
public enum LabDemo {
    struct Manifest: Codable {
        let profile: LabProfile
        let identifier: String
        let image: String
        var ready: Bool
    }
    public static func run(root: URL, arguments: [String]) throws {
        var args=arguments
        guard !args.isEmpty else { throw LabError("demo requires up|start|stop|status|compare|sql|inspect|resolve|down and --profile") }
        let action=args.removeFirst(), profile=try takeProfile(&args)
        let session=Session(root:root,profile:profile)
        switch action {
        case "up":
            try require(args.isEmpty || args == ["--skip-build"],"demo up accepts --skip-build")
            try session.up(build:args.isEmpty)
        case "sql":
            try require(args.count == 1,"demo sql requires a SQL file")
            let file=URL(fileURLWithPath:args[0],relativeTo:root), bytes=try Data(contentsOf:file)
            try require(bytes.count <= 1024*1024,"demo SQL exceeds 1 MiB")
            guard let sql=String(data:bytes,encoding:.utf8) else { throw LabError("SQL must be UTF-8") }
            try session.load(); print(try session.fixture!.sql(.source,profile.session+sql))
        case "inspect","resolve":
            try require(profile == .reverse,"audited recovery is only implemented for the InnoDB profile")
            if action == "inspect" { try require(args.isEmpty,"inspect takes no additional arguments") }
            else { try require(args.count == 5 && ["retry","skip","mark-applied"].contains(args[0]) && args[1] == "--gtids" && args[3] == "--reason","resolve ACTION --gtids SET --reason TEXT") }
            try session.load()
            try LabTests.printJSON(session.fixture!.recovery([action]+args,label:"demo-recovery-"+runID()))
        default:
            try require(args.isEmpty,"unexpected demo arguments")
            switch action {
            case "start": try session.load(); try session.start()
            case "stop": try session.load(); try session.stop()
            case "status": try session.load(ready:false); try session.status()
            case "compare": try session.load(); try session.compare()
            case "down": try session.load(ready:false); try session.down()
            default: throw LabError("unknown demo action: "+action)
            }
        }
    }
    static func qualify(root: URL, profile: LabProfile, build: Bool,onEvidence: ((URL)->Void)? = nil) throws {
        let session=Session(root:root,profile:profile,category:"lab-demo-tests/"+profile.rawValue+"/"+runID())
        onEvidence?(session.manifestURL.deletingLastPathComponent())
        var failure: Error?
        do {
            try session.up(build:build)
            try require(try session.lifecycle() == "NOT_STARTED","demo unexpectedly initialized state")
            try session.status(); try session.start()
            _ = try session.fixture!.sql(.source,"INSERT INTO reverse_poc.aux VALUES(1,7)")
            try session.compare(); try session.stop()
            try session.start()
            _ = try session.fixture!.sql(.source,"UPDATE reverse_poc.aux SET counter=8 WHERE id=1")
            try session.compare(); try session.stop()
            _ = try session.fixture!.docker(["rm","-f",session.applier.name])
            try session.up(build:false)
            try require(try session.lifecycle() == "STOPPED","container repair reset saved state")
            try session.start(); try session.compare(); try session.stop()
        } catch { failure=error }
        if session.fixture != nil {
            do { try session.down() } catch { if failure == nil { failure=error } }
            try writeJSON(["result":failure == nil ? "passed" : "failed","profile":profile.rawValue,"error":failure.map(String.init(describing:)) ?? ""],to:session.fixture!.output.appendingPathComponent("result.json"))
        }
        if let failure { throw failure }
    }
    static func takeProfile(_ args: inout [String]) throws -> LabProfile {
        guard let index=args.firstIndex(of:"--profile"), index+1 < args.count,
              let profile=LabProfile(rawValue:args[index+1]) else { throw LabError("select one explicit --profile: "+LabProfile.allCases.map(\.rawValue).joined(separator:" | ")) }
        args.removeSubrange(index...index+1)
        try require(!args.contains("--profile"),"duplicate --profile")
        return profile
    }
    final class Session {
        let root: URL, profile: LabProfile, category: String, manifestURL: URL
        var fixture: LabFixture?
        var applier: LabApplier { LabApplier(fixture!) }
        init(root: URL, profile: LabProfile, category: String? = nil) {
            self.root=root; self.profile=profile; self.category=category ?? "demos/"+profile.rawValue
            // All generated state stays under artifacts, including qualification.
            manifestURL=root.appendingPathComponent("artifacts/"+self.category+"/current.json")
        }
        func load(ready: Bool = true) throws {
            let m=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:manifestURL))
            try require(m.profile == profile && (!ready || m.ready),"demo profile differs or setup is incomplete")
            try require(m.identifier.range(of:#"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"#,options:.regularExpression) != nil && m.image.range(of:#"^sha256:[0-9a-f]{64}$"#,options:.regularExpression) != nil,"invalid demo identity")
            fixture=LabFixture(root:root,category:category,identifier:m.identifier,image:m.image,profile:profile)
        }
        func up(build: Bool) throws {
            if FileManager.default.fileExists(atPath:manifestURL.path) { try load(); try applier.ensureIdleContainer(); instructions(); return }
            let image=try LabBuild.prepare(root:root,build:build,coverage:false), id=runID()
            var m=Manifest(profile:profile,identifier:id,image:image,ready:false)
            try FileManager.default.createDirectory(at:manifestURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(m).write(to:manifestURL,options:.atomic)
            let f=LabFixture(root:root,category:category,identifier:id,image:image,profile:profile); fixture=f
            try f.prepare(build:false); try f.recordRuntime()
            var source=f.config["source"] as! [String:Any]; source.removeValue(forKey:"stopAfterTransactions"); f.config["source"]=source
            try f.installConfig(); try applier.ensureIdleContainer()
            m.ready=true; try JSONEncoder().encode(m).write(to:manifestURL,options:.atomic)
            instructions()
        }
        func instructions() {
            let f=fixture!, prefix="swift run replicator-lab demo"
            print("Profile: "+profile.rawValue+"; config: "+f.output.path+"/apply.yaml")
            print("Start: \(prefix) start --profile \(profile.rawValue)")
            print("Try: \(prefix) sql --profile \(profile.rawValue) examples/lab-demo.sql")
            print("Compare: \(prefix) compare --profile \(profile.rawValue)")
            for role: LabProfile.Role in [.source,.target,.native] { print("\(role.rawValue) shell: docker exec -it -e MYSQL_PWD=fixture-root-only \(f.h.project)-\(profile.service(role))-1 mysql --no-defaults -uroot") }
            print("Drain/cleanup: \(prefix) stop|down --profile \(profile.rawValue); see docs/TEST_LAB.md")
        }
        func lifecycle() throws -> String {
            guard try applier.hasState() else { return "NOT_STARTED" }
            try require(try applier.pids().isEmpty,"offline state inspection requires a stopped applier")
            let f=fixture!, directory=f.output.appendingPathComponent("inspection-"+runID())
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            _ = try f.docker(["cp",f.helper+":/evidence/state",directory.path])
            return try f.runner.run(["sqlite3",directory.appendingPathComponent("state/state.sqlite").path,"SELECT lifecycle FROM state"]).text
        }
        func start() throws {
            try require(try applier.pids().isEmpty,"applier already running")
            let state=try lifecycle(); try require(["NOT_STARTED","STOPPED"].contains(state),"state is "+state+"; resolve it explicitly before restart")
            try applier.start(initialize:state == "NOT_STARTED")
            let deadline=Date().addingTimeInterval(30)
            while true {
                if let p=try applier.latestProgress(), p["lifecycle"] as? String == "RUNNING", try !applier.pids().isEmpty { break }
                let logs=try applier.logs(tail:true)
                try require(logs.stderr.isEmpty && Date() < deadline,"applier did not start: "+String(decoding:logs.stderr,as:UTF8.self))
                Thread.sleep(forTimeInterval:0.1)
            }
        }
        func stop() throws { try applier.drain(); try applier.archiveLogs(); try require(try ["STOPPED","NOT_STARTED"].contains(lifecycle()),"applier did not stop cleanly") }
        func status() throws {
            let f=fixture!, running=try !applier.pids().isEmpty
            try LabTests.printJSON(["profile":profile.rawValue,"topology":profile.topology,"artifacts":f.output.path,"container":try applier.containerState(),"lifecycle":running ? "RUNNING" : try lifecycle(),"progress":try applier.containerState() == "running" ? (try applier.latestProgress() ?? [:]) : [:]])
        }
        func compare() throws {
            let f=fixture!, resume=try !applier.pids().isEmpty, end=try f.boundary()
            let deadline=Date().addingTimeInterval(60)
            while true {
                if let p=try applier.latestProgress(), let gtids=p["appliedGTIDSet"] as? String,
                   try f.sql(.source,"SELECT GTID_SUBSET('\(end.gtids)','\(gtids)')") == "1" { break }
                try require(resume && Date() < deadline,"applier has not caught up")
                Thread.sleep(forTimeInterval:0.1)
            }
            if resume { try stop() }
            try require(try lifecycle() == "STOPPED","comparison requires clean state")
            try f.compare(); try require(try f.boundary().gtids == end.gtids,"pause source writes during comparison")
            try writeJSON(["result":"passed","profile":profile.rawValue,"boundary":end.json,"scope":"preloaded reverse_poc.items and reverse_poc.aux"],to:f.output.appendingPathComponent("comparison.json"))
            if resume { try start() }
            print("PASS: baseline rows, schema and checkpoint agree")
        }
        func down() throws {
            let f=fixture!
            try applier.drain(); try applier.archiveLogs()
            if try f.docker(["inspect",f.helper],checked:false).status == 0 { _ = try f.docker(["cp",f.helper+":/evidence",f.output.appendingPathComponent("evidence-"+runID()).path]) }
            f.clients=[applier.name]; try f.cleanup(); try FileManager.default.removeItem(at:manifestURL)
        }
    }
}
