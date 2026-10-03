import Foundation

/// Fixed-backlog experiment. Source generation, native I/O, native SQL and
/// blackhole capture run in separate phases so source TPS cannot cap decoding.
public enum CaptureBenchmark {
    static func validate(_ result: [String:Any], events: Int, rowsPerEvent: Int, final: Boundary) throws -> [String:Any] {
        guard let capture=result["capture"] as? [String:Any], let download=capture["download"] as? [String:Any],
              let timings=capture["stageTimings"] as? [String:Any],
              let elapsed=result["elapsedSeconds"] as? Double, elapsed.isFinite, elapsed > 0 else { throw LabError("missing blackhole timings") }
        try require(result["kind"] as? String == "blackhole_summary" && result["writesApplied"] as? Int == 0
                    && result["durableProgress"] as? Bool == false && capture["durableProgress"] as? Bool == false
                    && download["durable"] as? Bool == false,"blackhole published applied/durable progress")
        try require(capture["transactions"] as? Int == events && result["rowsDecoded"] as? Int == events*rowsPerEvent,"blackhole transaction/row count differs")
        try require(capture["completeGTIDSet"] as? String == final.gtids && download["reachedEOF"] as? Bool == true,"blackhole did not decode full backlog")
        try require(capture["pendingTransactionStart"] == nil || capture["pendingTransactionStart"] is NSNull,"blackhole left an incomplete transaction")
        guard let bytes=capture["eventBytesReceived"] as? String, let decodedBytes=UInt64(bytes), decodedBytes > 0,
              (download["eventBytes"] as? NSNumber)?.uint64Value == decodedBytes else { throw LabError("downloaded/decoded byte counts differ") }
        let boundary=capture["lastCompleteBoundary"] as? [String:Any]
        try require(boundary?["file"] as? String == final.file && boundary?["position"] as? String == String(final.position),"blackhole final decoded position differs")
        return timings
    }

    public static func run(root: URL, arguments: [String]) throws {
        let allowed:Set<String>=["--skip-build","--events","--threads","--rate","--workload","--rows-per-event","--payload-bytes","--timeout","--decoder-profile"]
        try require(arguments.filter { $0.hasPrefix("--") }.allSatisfy { allowed.contains($0) },"unsupported capture benchmark option")
        var options=try PerformanceOptions(arguments:arguments)
        options.applierProfiling=false // This benchmark never starts the applier.
        let session=DemoSession.Session(root:root,category:"capture-performance/"+runID())
        let runner=ProcessRunner(root:root), tag="mysql-replicator-benchmark:sysbench"
        var failure:Error?, output:URL?, loadName:String?
        var report:[String:Any]=["result":"failed","options":try jsonObject(options),
            "scope":"fixed backlog; sequential native receiver-only, native SQL from relay, and custom blackhole; shared ARM host may emulate x86_64; blackhole does not apply writes or verify target rows"]
        do {
            if options.build { _ = try runner.run(["docker","build","--progress=plain","-t",tag,"docker/performance"],timeout:600,onOutput:{ FileHandle.standardError.write($0) }) }
            try session.up(build:options.build,showInstructions:false)
            output=session.h.output
            report["replicator_image"]=session.manifest!.image
            report["revision"]=try runner.run(["git","rev-parse","HEAD"]).text
            report["working_tree"]=try runner.run(["git","status","--short"]).text
            report["docker_host"]=try runner.run(["docker","info","--format","architecture={{.Architecture}} kernel={{.KernelVersion}} cpus={{.NCPU}} memory_bytes={{.MemTotal}}"] ).text
            try writeJSON(DDLCoverageEvidence.inputs(root:root),to:output!.appendingPathComponent("inputs.json"))
            let image=try session.docker(["image","inspect",tag,"--format","{{.Id}}"] ).text
            report["load_image"]=image
            let hostHash=try runner.run(["openssl","dgst","-sha256",root.appendingPathComponent("docker/performance/workload.lua").path]).text.suffix(64)
            let imageHash=try session.docker(["run","--rm","--network","none","--entrypoint","sha256sum",image,"/workload.lua"]).text.prefix(64)
            try require(hostHash == imageHash,"stale workload image; rebuild")
            _ = try session.h.sql("source","SET SESSION sql_log_bin=0; CREATE USER 'benchmark_fixture'@'%' IDENTIFIED BY 'fixture-benchmark-only' REQUIRE SSL; GRANT SELECT,INSERT,UPDATE,DELETE ON demo.* TO 'benchmark_fixture'@'%'")
            try PerformanceBenchmark.prepareLoadTLS(session)
            _ = try session.h.sql("source","CREATE DATABASE demo CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE demo.bench(id BIGINT UNSIGNED NOT NULL PRIMARY KEY,payload VARCHAR(1024) NOT NULL,quantity BIGINT UNSIGNED NOT NULL)")
            let baseline=try session.h.boundary("source")
            let uuid=try session.h.sql("source","SELECT @@server_uuid")
            let caught=try session.h.sql("native","SELECT SOURCE_POS_WAIT('\(baseline.file)',\(baseline.position),30)")
            try require(caught != "NULL" && caught != "-1","native schema setup did not catch up")
            _ = try session.h.sql("native","STOP REPLICA; SET GLOBAL sync_relay_log=0")
            report["baseline"]=baseline.json
            report["native_settings"]=try session.h.sql("native","SELECT VERSION(),@@GLOBAL.replica_parallel_workers,@@GLOBAL.sync_relay_log,@@GLOBAL.sync_binlog")
            let name=session.h.project+"-sysbench"; loadName=name
            _ = try session.docker(["run","-d","--name",name,"--network",session.h.project+"_fixture",
                "--mount","type=volume,src=\(session.volume),dst=/evidence,readonly","--workdir","/evidence/tls",image,
                "--mysql-host=source","--mysql-user=benchmark_fixture","--mysql-password=fixture-benchmark-only",
                "--mysql-db=demo","--mysql-ssl=on","--mysql-ignore-errors=","--db-ps-mode=disable",
                "--events=\(options.events)","--time=0","--threads=\(options.threads)","--rate=\(options.rate)",
                "--rows-per-event=\(options.rowsPerEvent)","--payload-bytes=\(options.payloadBytes)",
                "--workload=\(options.workload)","--report-interval=1","run"])
            let deadline=Date().addingTimeInterval(Double(options.timeoutSeconds))
            while try session.docker(["inspect",name,"--format","{{.State.Running}}"] ).text == "true" {
                try require(Date() < deadline,"load timed out"); Thread.sleep(forTimeInterval:0.2)
            }
            try require(session.docker(["inspect",name,"--format","{{.State.ExitCode}}"] ).text == "0","source workload failed")
            let logs=try session.docker(["logs",name])
            try (logs.stdout+logs.stderr).write(to:output!.appendingPathComponent("sysbench.log"))
            let totals=try PerformanceBenchmark.sysbenchTotals(String(decoding:logs.stdout,as:UTF8.self))
            let end=try session.h.boundary("source")
            let gtids=try session.h.sql("source","SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,'\(baseline.gtids)')")
            try require(totals.events == options.events && PerformanceBenchmark.transactionCount(gtids,sourceUUID:uuid) == options.events,"source workload GTID count differs")
            report["source_load_seconds"]=totals.seconds; report["workload_end"]=end.json
            // Exercise physical rotation/FDE handling in every fixed-backlog run.
            _ = try session.h.sql("source","FLUSH BINARY LOGS")
            let final=try session.h.boundary("source")
            report["final_boundary"]=final.json
            report["source_binlogs"]=try session.h.sql("source","SHOW BINARY LOGS")
            func elapsed(_ start:UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds-start)/1e9 }
            let ioStart=DispatchTime.now().uptimeNanoseconds
            _ = try session.h.sql("native","START REPLICA IO_THREAD")
            var previous:Double=0
            while true {
                let status=try session.h.status()
                let observed=elapsed(ioStart)
                try require(status["Last_IO_Errno"] == "0" && status["Replica_SQL_Running"] == "No","native receiver failed or SQL thread unexpectedly running")
                if status["Source_Log_File"] == final.file, let position=status["Read_Source_Log_Pos"].flatMap(UInt64.init), position >= final.position {
                    report["native_receiver_completion_lower_seconds"]=previous
                    report["native_receiver_completion_upper_seconds"]=observed
                    try writeJSON(status,to:output!.appendingPathComponent("native-received.json")); break
                }
                try require(observed < Double(options.timeoutSeconds),"native receiver catch-up timed out")
                previous=observed; Thread.sleep(forTimeInterval:0.05)
            }
            _ = try session.h.sql("native","STOP REPLICA IO_THREAD")
            let sqlStart=DispatchTime.now().uptimeNanoseconds
            _ = try session.h.sql("native","START REPLICA SQL_THREAD")
            let applied=try session.h.sql("native","SELECT WAIT_FOR_EXECUTED_GTID_SET('\(end.gtids)',\(options.timeoutSeconds))")
            try require(applied == "0","native SQL did not apply backlog")
            report["native_sql_from_relay_observed_seconds"]=elapsed(sqlStart)
            _ = try session.h.sql("native","STOP REPLICA SQL_THREAD")
            // Compare exact native final rows in bounded pages, outside timers.
            var cursor:UInt64=0, verified=0
            while true {
                let sql="SELECT id,HEX(payload),quantity FROM demo.bench WHERE id>\(cursor) ORDER BY id LIMIT 1000"
                let source=try session.h.sql("source",sql)
                try require(session.h.sql("native",sql) == source,"native row mismatch")
                let lines=source.split(separator:"\n"); if lines.isEmpty { break }
                guard let next=lines.last?.split(separator:"\t").first.flatMap({ UInt64($0) }), next > cursor else { throw LabError("invalid verification cursor") }
                cursor=next; verified += lines.count
            }
            report["native_rows_verified"]=verified
            let sourceConfig:[String:Any]=["version":2,"host":"source","port":3306,"username":"capture_fixture",
                "passwordEnvironment":"SOURCE_PASSWORD","serverHostname":"source","caFile":"/evidence/tls/ca.pem",
                "serverID":9200,"sourceUUID":uuid,"mode":"gtid","start":["file":baseline.file,"position":baseline.position,"executedGTIDs":baseline.gtids],
                "nonBlocking":true,"idleTimeoutSeconds":30,"decoderProfiling":options.decoderProfiling]
            try writeYAML(sourceConfig,to:output!.appendingPathComponent("blackhole-source.yaml"))
            _ = try session.docker(["cp",output!.appendingPathComponent("blackhole-source.yaml").path,session.applier+":/evidence/blackhole-source.yaml"])
            let blackhole=try session.docker(["exec",session.applier,"mysql-replicator","blackhole","--source-config","/evidence/blackhole-source.yaml"],checked:false,timeout:Double(options.timeoutSeconds))
            try blackhole.stdout.write(to:output!.appendingPathComponent("blackhole.json"))
            try blackhole.stderr.write(to:output!.appendingPathComponent("blackhole.stderr"))
            try require(blackhole.status == 0,"blackhole capture failed; inspect blackhole.stderr")
            guard let result=try JSONSerialization.jsonObject(with:blackhole.stdout) as? [String:Any] else { throw LabError("invalid blackhole result") }
            let timings=try validate(result,events:options.events,rowsPerEvent:options.rowsPerEvent,final:final)
            let capture=result["capture"] as! [String:Any], download=capture["download"] as! [String:Any]
            try require(session.h.boundary("source").gtids == end.gtids,"source changed during capture")
            try require(!session.hasState(),"blackhole unexpectedly created apply state")
            report["blackhole"]=result
            try writeJSON(timings,to:output!.appendingPathComponent("stage-timings.json"))
            if options.decoderProfiling {
                try require(timings["decode.rust.crc32"] != nil && timings["binlog.packet_frame"] != nil,"missing detailed profile")
                try PerformanceBenchmark.decoderProfile(timings).write(to:output!.appendingPathComponent("decoder-profile.tsv"),atomically:true,encoding:.utf8)
            }
            report["result"]="passed"
            print("Blackhole seconds: \(result["elapsedSeconds"]!); receiver seconds: \(download["receiverSeconds"]!); transactions: \(options.events)")
            print("Native receiver upper bound: \(report["native_receiver_completion_upper_seconds"]!); native SQL from relay: \(report["native_sql_from_relay_observed_seconds"]!)")
        } catch { failure=error; report["error"]=String(describing:error); if output == nil { output=session.harness?.output } }
        if let loadName {
            _ = try? session.docker(["stop","--time","5",loadName],checked:false)
            _ = try? session.docker(["rm","-f",loadName],checked:false)
        }
        if FileManager.default.fileExists(atPath:session.manifestURL.path) {
            do { try session.down(); report["cleanup"]="passed" }
            catch { report["cleanup_error"]=String(describing:error); if failure == nil { failure=error } }
        }
        if let output {
            if failure != nil { report["result"]="failed" }
            try writeJSON(report,to:output.appendingPathComponent("result.json"))
            print("Capture benchmark \(failure == nil ? "passed" : "failed"): \(output.path)")
        }
        if let failure { throw failure }
    }
}
