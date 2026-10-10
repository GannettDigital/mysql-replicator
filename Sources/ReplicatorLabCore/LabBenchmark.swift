import Foundation

/// Identical source workload and timing method for each qualified topology.
public enum LabBenchmark {
    struct Options {
        let profile: LabProfile
        var mode="backlog", workload="insert"
        var build=true, events=1000
        var decoderProfiling=false, applierProfiling=true, batchTransactions=8
        var forwardedArguments: [String]=[]
        init(_ arguments: [String]) throws {
            var args=arguments
            profile=try LabProfile.takeProfile(&args)

            if let index=args.firstIndex(of:"--mode") {
                try require(index+1 < args.count,"missing benchmark mode")
                mode=args[index+1]; args.removeSubrange(index...index+1)
            }
            try require(!args.contains("--mode"),"duplicate benchmark mode")
            if mode == "streaming" || mode == "capture" {
                try require(profile == .forward,"\(mode) measurement is not implemented for this profile; use --mode backlog")
                forwardedArguments=args
                return
            }
            try require(mode == "backlog","unknown benchmark mode")
            while !args.isEmpty {
                let flag=args.removeFirst()
                if flag == "--skip-build" { build=false; continue }
                try require(!args.isEmpty,"missing benchmark option value")
                let value=args.removeFirst()
                if flag == "--events", let n=Int(value) { events=n }
                else if flag == "--workload" { workload=value }
                else if flag == "--batch-transactions", let n=Int(value) { batchTransactions=n }
                else if flag == "--decoder-profile" || flag == "--applier-profile" {
                    try require(["on","off"].contains(value),flag+" must be on or off")
                    if flag == "--decoder-profile" { decoderProfiling=value == "on" }
                    else { applierProfiling=value == "on" }
                }
                else { throw LabError("unknown benchmark option: "+flag) }
            }
            try require((1...100000).contains(events),"events must be 1...100000")
            try require((1...256).contains(batchTransactions),"batch-transactions must be 1...256")
            try require(["insert","multi-table-transaction"].contains(workload),"unknown backlog workload")
            try require(workload == "insert" || profile.transactionalTarget,"multi-table transactions are outside the MyISAM apply contract")
        }
    }

    public static func run(root: URL, arguments: [String]) throws {
        let options=try Options(arguments), profile=options.profile
        if options.mode == "streaming" { try PerformanceBenchmark.run(root:root,arguments:options.forwardedArguments); return }
        if options.mode == "capture" { try CaptureBenchmark.run(root:root,arguments:options.forwardedArguments); return }
        let mode=options.mode, workload=options.workload, events=options.events, build=options.build
        let image=try LabBuild.prepare(root:root,build:build,coverage:false)
        let f=LabFixture(root:root,category:"lab-benchmark/"+profile.rawValue,image:image,profile:profile)
        var result: [String:Any]=["result":"failed","profile":profile.rawValue,"topology":profile.topology,"mode":mode,"workload":workload,"events":events,
            "decoder_profiling":options.decoderProfiling,"applier_profiling":options.applierProfiling,"batch_transactions":options.batchTransactions,
            "timing":"Sequential backlog replay; monotonic host wall time includes startup/control overhead. Different target versions and engines are recorded, not normalized."]
        var failure: Error?
        do {
            try f.prepare(build:false); try f.recordRuntime()
            _ = try f.sql(.native,profile.nativeVersion.stopReplica)
            let statements=(0..<events).map { i -> String in
                let insert="INSERT INTO reverse_poc.aux VALUES(\(1000+i),\(i));"
                return workload == "insert" ? insert : "START TRANSACTION; "+insert+" UPDATE reverse_poc.items SET amount=\(i).00 WHERE id=1; COMMIT;"
            }.joined(separator:"\n")
            let file=f.output.appendingPathComponent("workload.sql"); try statements.write(to:file,atomically:true,encoding:.utf8)
            let sourceID=try f.h.compose(["ps","-q",profile.service(.source)]).text
            _ = try f.docker(["cp",file.path,sourceID+":/tmp/lab-workload.sql"])
            _ = try f.h.compose(["exec","-T","-e","MYSQL_PWD=fixture-root-only",profile.service(.source),"sh","-c","mysql --no-defaults -uroot < /tmp/lab-workload.sql"],timeout:600)
            let end=try f.boundary()
            try require(try f.sql(.source,"SELECT COUNT(*),SUM(counter) FROM reverse_poc.aux") == "\(events)\t\(Int64(events)*Int64(events-1)/2)","source workload count/sum differs")
            let nativeBefore=try f.counters(profile.service(.native)), targetBefore=try f.counters(profile.service(.target))
            let nativeStart=try f.boundary(.native), targetStart=try f.boundary(.target)
            let start=ProcessInfo.processInfo.systemUptime
            _ = try f.sql(.native,profile.nativeVersion.startReplica)
            try f.awaitNative(); let nativeSeconds=ProcessInfo.processInfo.systemUptime-start
            let nativeAfter=try f.counters(profile.service(.native))
            let nativeEnd=try f.boundary(.native)
            var source=f.config["source"] as! [String:Any]; source["stopAfterTransactions"]=events
            source["decoderProfiling"]=options.decoderProfiling; f.config["source"]=source
            f.config["applierProfiling"]=options.applierProfiling
            f.config["batch"]=["maximumTransactions":options.batchTransactions]
            try f.installConfig()
            let applyStart=ProcessInfo.processInfo.systemUptime
            let client=try f.startClient("benchmark",arguments:["run","--config","/evidence/apply.yaml","--initialize"])
            let exit=try f.runner.run(["docker","wait",client],timeout:1800).text
            let seconds=ProcessInfo.processInfo.systemUptime-applyStart, logs=try f.docker(["logs",client])
            try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent("applier.ndjson"))
            try require(exit == "0","benchmark applier failed; inspect applier.ndjson")
            let targetAfter=try f.counters(profile.service(.target))
            let targetEnd=try f.boundary(.target)
            guard let last=logs.stderr.split(separator:10).last,
                  let summary=try JSONSerialization.jsonObject(with:Data(last)) as? [String:Any],
                  let gtids=summary["appliedGTIDSet"] as? String else { throw LabError("missing final benchmark summary") }
            try require(summary["transactionsApplied"] as? Int == events && summary["lifecycle"] as? String == "STOPPED","benchmark checkpoint counts differ")
            try require(try f.sql(.source,"SELECT GTID_SUBSET('\(end.gtids)','\(gtids)')") == "1","benchmark checkpoint does not cover source")
            try f.compare()
            var deltas: [String:[String:Int64]]=[:]
            for (role,before,after) in [(LabProfile.Role.native,nativeBefore,nativeAfter),(.target,targetBefore,targetAfter)] {
                deltas[role.rawValue]=after.reduce(into:[:]) { $0[$1.key]=$1.value-(before[$1.key] ?? 0) }
            }
            result["counter_scope"]="Before native replay/applier startup to completion, before row verification; includes control and status queries."
            result["binlog_boundaries"]=["native":["start":nativeStart.json,"end":nativeEnd.json],"target":["start":targetStart.json,"end":targetEnd.json]]
            result["native_seconds"]=nativeSeconds; result["applier_seconds"]=seconds
            result["native_transactions_per_second"]=Double(events)/nativeSeconds; result["applier_transactions_per_second"]=Double(events)/seconds
            result["counter_deltas"]=deltas; result["summary"]=summary; result["source_end"]=end.json
            guard let timings=summary["stageTimings"] as? [String:Any] else { throw LabError("missing benchmark stage timings") }
            result["stage_timing_scope"]="Worker-local elapsed time including startup/stop. seconds is inclusive; selfSeconds excludes nested timers on that worker. Workers overlap; totals are not wall time or CPU time."
            try writeJSON(timings,to:f.output.appendingPathComponent("stage-timings.json"))
            if options.decoderProfiling {
                try require(timings["decode.call.event"] != nil,"missing decoder profile")
                try PerformanceBenchmark.decoderProfile(timings).write(to:f.output.appendingPathComponent("decoder-profile.tsv"),atomically:true,encoding:.utf8)
            }
            if options.applierProfiling {
                try PerformanceBenchmark.applierProfile(timings).write(to:f.output.appendingPathComponent("applier-profile.tsv"),atomically:true,encoding:.utf8)
            }
            _ = try f.docker(["cp",f.helper+":/evidence/state",f.output.path])
            result["result"]="passed"
        } catch { failure=error; result["error"]=String(describing:error) }
        do { try f.cleanup() } catch { result["cleanup_error"]=String(describing:error); result["result"]="failed"; if failure == nil { failure=error } }
        try writeJSON(result,to:f.output.appendingPathComponent("result.json"))
        print("Benchmark evidence: "+f.output.path)
        if let failure { throw failure }
    }
}
