import Foundation

/// Profile-specific retained sessions never attach to the legacy demo directories.
public enum LabDemo {
    struct Manifest: Codable {
        let profile: LabProfile
        let identifier: String
        let image: String
        var ready: Bool
        var codeCoverage: Bool? = nil
        func validate() throws {
            try require(identifier.range(of:#"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z"#,options:.regularExpression) != nil && image.range(of:#"^sha256:[0-9a-f]{64}\z"#,options:.regularExpression) != nil,"invalid demo identity")
        }
    }
    public static func run(root: URL, arguments: [String]) throws {
        var args=arguments
        guard !args.isEmpty else { throw LabError("demo requires up|start|stop|status|compare|sql|fail|skip|inspect|resolve|down|legacy-down and --profile") }
        let action=args.removeFirst(), profile=try LabProfile.takeProfile(&args)
        let session=Session(root:root,profile:profile)
        switch action {
        case "up":
            try require(Set(args).isSubset(of:["--skip-build","--coverage"]),"demo up accepts --skip-build and --coverage")
            try session.up(build:!args.contains("--skip-build"),coverage:args.contains("--coverage") ? true : nil)
        case "sql":
            try require(args.count == 1,"demo sql requires a SQL file")
            try session.load(); try session.executeSQL(file:URL(fileURLWithPath:args[0],relativeTo:root))
        case "legacy-down":
            try require(args.isEmpty,"legacy-down takes no additional arguments")
            try cleanupLegacy(root:root,profile:profile)
        case "skip":
            try require(args.count == 1 && profile == .forward,"demo skip requires one GTID and the MyISAM profile")
            try session.load(); print(try session.cli(["skip",args[0]]).text)
        case "fail":
            try require(args.isEmpty && profile == .forward,"demo fail is the MyISAM explicit-engine refusal")
            try session.load(); try session.fail()
        case "compare":
            try require(args.isEmpty || (profile == .forward && args == ["--expect-blocked"]),"compare accepts --expect-blocked on MyISAM only")
            try session.load()
            if args.isEmpty { try session.compare() } else { try session.verifyBlocked() }
        case "inspect","resolve":
            try require(profile == .reverse,"audited recovery is only implemented for the InnoDB profile")
            if action == "inspect" { try require(args.isEmpty,"inspect takes no additional arguments") }
            else { try require(args.count == 5 && ["retry","skip","mark-applied"].contains(args[0]) && args[1] == "--gtids" && args[3] == "--reason","resolve ACTION --gtids SET --reason TEXT") }
            try session.load()
            print(try session.cli(["recovery",action]+args).text)
        default:
            try require(args.isEmpty,"unexpected demo arguments")
            switch action {
            case "start": try session.load(); try session.start()
            case "stop": try session.load(); try session.stop()
            case "status": try session.load(ready:false); try session.status()
            case "down": try session.load(ready:false); try session.down()
            default: throw LabError("unknown demo action: "+action)
            }
        }
    }
    static func cleanupLegacy(root: URL, profile: LabProfile) throws {
        if profile == .forward { try ForwardBenchmarkFixture(root:root,category:"demo").down(); return }
        let session=Session(root:root,profile:profile,category:"reverse-demo")
        let object=try JSONSerialization.jsonObject(with:Data(contentsOf:session.manifestURL)) as? [String:Any]
        guard let identifier=object?["identifier"] as? String, var image=object?["image"] as? String else { throw LabError("invalid legacy session") }
        if object?["ready"] as? Bool == false && image == "mysql-replicator-packaging:reverse" {
            image=try ProcessRunner(root:root).run(["docker","image","inspect",image,"--format","{{.Id}}"] ).text
        }
        let m=Manifest(profile:profile,identifier:identifier,image:image,ready:false)
        try m.validate()
        session.fixture=LabFixture(root:root,category:"reverse-demo",identifier:m.identifier,image:m.image,profile:profile)
        try session.down()
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
            try m.validate()
            fixture=LabFixture(root:root,category:category,identifier:m.identifier,image:m.image,profile:profile,codeCoverage:m.codeCoverage ?? false)
            let invocations=fixture!.output.appendingPathComponent("code-coverage-invocations.json")
            if FileManager.default.fileExists(atPath:invocations.path) { fixture!.coverageInvocations=(try JSONSerialization.jsonObject(with:Data(contentsOf:invocations))) as? [[String:Any]] ?? [] }
            configureFixture()
        }
        func up(build: Bool, coverage: Bool? = nil, image pinnedImage: String? = nil) throws {
            if FileManager.default.fileExists(atPath:manifestURL.path) {
                if fixture == nil { try load() }
                try require(coverage == nil || coverage == fixture!.codeCoverage,"demo coverage mode is pinned; use down before changing it")
                try applier.ensureIdleContainer(); instructions(); return
            }
            let enabled=coverage ?? false
            let image=try pinnedImage ?? LabBuild.prepare(root:root,build:build,coverage:enabled,demo:true), id=runID()
            var m=Manifest(profile:profile,identifier:id,image:image,ready:false,codeCoverage:enabled)
            try FileManager.default.createDirectory(at:manifestURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(m).write(to:manifestURL,options:.atomic)
            let f=LabFixture(root:root,category:category,identifier:id,image:image,profile:profile,codeCoverage:enabled); fixture=f
            configureFixture()
            try f.prepare(build:false); try f.recordRuntime()
            var source=f.config["source"] as! [String:Any]; source.removeValue(forKey:"stopAfterTransactions"); source["idleTimeoutSeconds"]=30; f.config["source"]=source
            try f.installConfig(); try applier.ensureIdleContainer()
            m.ready=true; try JSONEncoder().encode(m).write(to:manifestURL,options:.atomic)
            instructions()
        }
        func configureFixture() {
            if profile == .forward { fixture!.h.composeEnvironment["FIXTURE_DISABLED_ENGINES"]="InnoDB" }
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
        func state(_ sql: String) throws -> String {
            let f=fixture!
            return try f.docker(["run","--rm","--platform","linux/amd64","--network","none","--mount","type=volume,src=\(f.volume),dst=/evidence","--entrypoint","/usr/local/bin/sqlite3",f.image,"-readonly","-cmd",".timeout 2000","/evidence/state/state.sqlite",sql]).text
        }
        func lifecycle() throws -> String {
            try applier.hasState() ? state("SELECT lifecycle FROM state") : "NOT_STARTED"
        }
        func cli(_ arguments: [String], checked: Bool = true) throws -> CommandResult {
            let f=fixture!, label="demo-cli-"+runID()
            let command: [String]
            if arguments.first == "run" { command=["run","--config","/evidence/apply.yaml"]+arguments.dropFirst() }
            else { command=arguments+["--config","/evidence/apply.yaml"] }
            let result=try f.docker(["run","--rm","--platform","linux/amd64","--network",f.h.project+"_fixture","--mount","type=volume,src=\(f.volume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only","--entrypoint","/usr/local/bin/mysql-replicator"]+CodeCoverage.environment(enabled:f.codeCoverage,label:label)+[f.image]+command,checked:false)
            if f.codeCoverage {
                f.coverageInvocations.append(["label":label,"exit_code":Int(result.status)])
                try writeJSON(f.coverageInvocations,to:f.output.appendingPathComponent("code-coverage-invocations.json"))
            }
            try require(!checked || result.status == 0,"demo CLI failed: "+String(decoding:result.stderr,as:UTF8.self))
            return result
        }
        func executeSQL(file: URL) throws {
            let bytes=try Data(contentsOf:file)
            try require(bytes.count <= 1024*1024,"demo SQL exceeds 1 MiB")
            guard let sql=String(data:bytes,encoding:.utf8) else { throw LabError("SQL must be UTF-8") }
            print(try fixture!.sql(.source,"SET NAMES utf8mb4; "+sql))
        }
        func start() throws {
            try require(try applier.pids().isEmpty,"applier already running")
            let state=try lifecycle(); try require(["NOT_STARTED","STOPPED"].contains(state),"state is "+state+"; resolve it explicitly before restart")
            try applier.start(initialize:state == "NOT_STARTED")
            let deadline=Date().addingTimeInterval(30)
            while true {
                if let p=try applier.latestProgress(), p["lifecycle"] as? String == "RUNNING", try !applier.pids().isEmpty { break }
                let logs=try applier.logs(tail:true)
                try require(Date() < deadline,"applier did not start: "+String(decoding:logs.stderr,as:UTF8.self))
                Thread.sleep(forTimeInterval:0.1)
            }
        }
        func stop() throws { try applier.drain(); try applier.archiveLogs(); try require(try ["STOPPED","NOT_STARTED"].contains(lifecycle()),"applier did not stop cleanly") }
        func status() throws {
            let f=fixture!, running=try !applier.pids().isEmpty
            var saved: [String:Any]=[:]
            if try applier.hasState() {
                let json=try state("SELECT json_object('lifecycle',lifecycle,'baselineGTIDSet',baseline_gtids,'appliedFile',applied_file,'appliedPosition',applied_position,'transactionsApplied',transactions_applied,'rowsApplied',rows_applied,'diagnostic',diagnostic) FROM state")
                saved=try JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any] ?? [:]
            }
            let native=try f.sql(.native,profile == .reverse ? "SHOW SLAVE STATUS\\G" : "SHOW REPLICA STATUS\\G")
            try LabTests.printJSON(["profile":profile.rawValue,"topology":profile.topology,"artifacts":f.output.path,"container":try applier.containerState(),"processRunning":running,"lifecycle":running ? "RUNNING" : (saved["lifecycle"] ?? "NOT_STARTED"),"state":saved,"native":native,"progress":try applier.containerState() == "running" ? (try applier.latestProgress() ?? [:]) : [:]])
        }
        func compare() throws {
            let f=fixture!, end=try f.boundary()
            try awaitApplied()
            // Read SQLite in its volume after the completed boundary. A comparison
            // must not interrupt a foreground writer or create extra snapshots.
            try require(try ["RUNNING","STOPPED"].contains(lifecycle()),"comparison requires running or cleanly stopped state")
            try f.compare()
            var observations: [String:[String:String]]=[:]
            for role in LabProfile.Role.allCases { observations[profile.service(role)]=try observation(role) }
            let source=observations[profile.service(.source)]!
            for role: LabProfile.Role in [.native,.target] {
                let target=observations[profile.service(role)]!
                for field in ["database","schema","rows_hex"] { try require(target[field] == source[field],"demo differs in "+field) }
                try require(target["engines"] == source["engines"]!.replacingOccurrences(of:"\tInnoDB",with:"\t"+profile.targetEngine),"demo engine mismatch")
            }
            try require(try f.boundary().gtids == end.gtids,"pause source writes during comparison")
            try writeJSON(["result":"passed","profile":profile.rawValue,"boundary":end.json,"checkpoint":try checkpoint(),"observations":observations,"scope":"demo.items plus preloaded reverse_poc.items and reverse_poc.aux"],to:f.output.appendingPathComponent("comparison.json"))
            print("PASS: demo rows, schema and checkpoint agree")
        }
        func down() throws {
            let f=fixture!
            try applier.drain(); try applier.archiveLogs()
            try f.collectCoverage(allowEmpty:true)
            if try f.docker(["inspect",f.helper],checked:false).status == 0 {
                let hadState=try applier.hasState(), archive=f.output.appendingPathComponent("evidence-"+runID())
                _ = try f.docker(["cp",f.helper+":/evidence",archive.path])
                try require(!hadState || FileManager.default.fileExists(atPath:archive.appendingPathComponent("state/state.sqlite").path),"cleanup failed to archive SQLite")
            }
            f.clients=[applier.name]; try f.cleanup(); try FileManager.default.removeItem(at:manifestURL)
        }
    }
}
