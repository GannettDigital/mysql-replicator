import Foundation

public struct PerformanceOptions: Codable {
    public var events = 1000
    public var threads = 1
    public var rate = 100
    public var rowsPerEvent = 1
    public var payloadBytes = 100
    public var workload = "insert"
    public var targetTransport = "tcp-tls"
    public var batchTransactions = 32
    public var sampleSeconds = 5
    public var timeoutSeconds = 300
    public var build = true

    public init(arguments: [String]) throws {
        var args = arguments.makeIterator()
        while let flag = args.next() {
            if flag == "--skip-build" { build = false; continue }
            guard let value = args.next() else { throw LabError("missing value for " + flag) }
            if flag == "--workload" { workload = value; continue }
            if flag == "--target-transport" { targetTransport = value; continue }
            guard let number = Int(value) else { throw LabError("expected integer for " + flag) }
            switch flag {
            case "--events": events = number
            case "--threads": threads = number
            case "--rate": rate = number
            case "--rows-per-event": rowsPerEvent = number
            case "--payload-bytes": payloadBytes = number
            case "--sample-seconds": sampleSeconds = number
            case "--timeout": timeoutSeconds = number
            case "--batch-transactions": batchTransactions = number
            default: throw LabError("unknown benchmark option: " + flag)
            }
        }
        try require((1...1_000_000).contains(events), "events must be 1...1000000")
        try require((1...32).contains(threads) && threads <= events, "threads must be 1...32 and no greater than events")
        try require((0...100_000).contains(rate), "rate must be 0...100000 (0 means unlimited)")
        try require((1...100).contains(rowsPerEvent), "rows-per-event must be 1...100")
        try require((0...1024).contains(payloadBytes), "payload-bytes must be 0...1024")
        try require(["insert", "mixed"].contains(workload), "workload must be insert or mixed")
        try require(["tcp-tls","unix-tls","unix"].contains(targetTransport),"target-transport must be tcp-tls, unix-tls or unix")
        try require((1...256).contains(batchTransactions),"batch-transactions must be 1...256")
        try require((1...30).contains(sampleSeconds), "sample-seconds must be 1...30")
        try require((10...3600).contains(timeoutSeconds), "timeout must be 10...3600 seconds per load/catch-up phase")
        try require(rate == 0 || Double(events) / Double(rate) < Double(timeoutSeconds), "requested load exceeds timeout; increase --timeout")
    }
}

/// A benchmark for the existing qualified topology, not a production capacity gate.
public enum PerformanceBenchmark {
    /// GTID_SUBTRACT supplies only post-baseline transactions on this isolated source.
    /// Refuse another SID, malformed/overlapping intervals, or counter overflow.
    static func transactionCount(_ value: String, sourceUUID: String) throws -> Int {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        try require(parts.count >= 2 && parts[0].lowercased() == sourceUUID.lowercased(), "unexpected benchmark GTID lineage")
        var count = 0, previous = 0
        for part in parts.dropFirst() {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), let lower = Int(ends[0]), let upper = Int(ends.last!),
                  lower > previous, upper >= lower else { throw LabError("invalid benchmark GTID interval") }
            let (next, overflow) = count.addingReportingOverflow(upper - lower + 1)
            try require(!overflow, "benchmark GTID count overflow")
            count = next; previous = upper
        }
        return count
    }

    static func sysbenchTotals(_ log: String) throws -> (events: Int, seconds: Double) {
        func field(_ prefix: String) throws -> String {
            let matches = log.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix(prefix) }
            try require(matches.count == 1, "missing or ambiguous sysbench total: " + prefix)
            return String(matches[0].dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let events = Int(try field("total number of events:")),
              let seconds = Double(try field("total time:").replacingOccurrences(of: "s", with: "")),
              events > 0, seconds.isFinite, seconds > 0 else { throw LabError("invalid sysbench totals") }
        return (events, seconds)
    }

    struct Sample: Codable {
        let phase: String
        let startSeconds: Double
        let endSeconds: Double
        let sourceBefore: Int
        let sourceAfter: Int
        let native: Int
        let replicator: Int
        let replicatorRows: Int
        // Source is polled on both sides of the replica observations. These are
        // bounds, not a simultaneous snapshot or a per-transaction latency.
        var nativeBacklogLower: Int { max(0, sourceBefore - native) }
        var nativeBacklogUpper: Int { max(0, sourceAfter - native) }
        var replicatorBacklogLower: Int { max(0, sourceBefore - replicator) }
        var replicatorBacklogUpper: Int { max(0, sourceAfter - replicator) }
        var tsv: String {
            [String(format: "%.3f", startSeconds), String(format: "%.3f", endSeconds), phase,
             String(sourceBefore), String(sourceAfter), String(native), String(replicator), String(replicatorRows),
             String(nativeBacklogLower), String(nativeBacklogUpper), String(replicatorBacklogLower), String(replicatorBacklogUpper)].joined(separator: "\t") + "\n"
        }
    }

    public static func run(root: URL, arguments: [String]) throws {
        let options = try PerformanceOptions(arguments: arguments)
        // A unique category isolates this run from the interactive demo and other benchmarks.
        let session = DemoSession.Session(root: root, category: "performance/" + runID())
        let runner = ProcessRunner(root: root)
        let loadTag = "mysql-replicator-benchmark:sysbench"
        var loadContainer: String?
        var failure: Error?
        var report: [String: Any] = ["schema_version": 1, "result": "failed", "options": try jsonObject(options),
            "scope": "shared-host source8.4/native8.4/target5.7; release x86_64 applier; no production capacity claim",
            "timing": "monotonic host polling; source statement latency is not replication latency"]
        var output: URL?
        do {
            if options.build {
                _ = try runner.run(["docker", "build", "--progress=plain", "-t", loadTag, "docker/performance"], timeout: 600,
                                   onOutput: { FileHandle.standardError.write($0) })
            }
            let loadImage = try runner.run(["docker", "image", "inspect", loadTag, "--format", "{{.Id}}"] ).text
            report["load_image"] = loadImage
            try session.up(build: options.build, showInstructions: false, targetTransport:options.targetTransport, batchTransactions:options.batchTransactions)
            output = session.h.output
            report["replicator_image"] = session.manifest!.image
            report["revision"] = try runner.run(["git", "rev-parse", "HEAD"]).text
            report["working_tree"] = try runner.run(["git", "status", "--short"]).text
            try writeJSON(DDLCoverageEvidence.inputs(root: root), to: output!.appendingPathComponent("inputs.json"))
            report["sysbench_version"] = try session.docker(["run", "--rm", "--network", "none", "--entrypoint", "sysbench", loadImage, "--version"]).text
            report["docker_host"] = try runner.run(["docker", "info", "--format", "architecture={{.Architecture}} kernel={{.KernelVersion}} cpus={{.NCPU}} memory_bytes={{.MemTotal}}"] ).text
            let services = try session.h.compose(["ps", "-q"]).text.split(separator: "\n").map(String.init)
            try session.docker(["inspect"] + services).stdout.write(to: output!.appendingPathComponent("containers.json"))
            // Permissions are fixture provisioning, deliberately outside the measured binlog.
            _ = try session.h.sql("source", "SET SESSION sql_log_bin=0; CREATE USER 'benchmark_fixture'@'%' IDENTIFIED BY 'fixture-benchmark-only' REQUIRE SSL; GRANT SELECT,INSERT,UPDATE,DELETE ON demo.* TO 'benchmark_fixture'@'%'")
            try prepareLoadTLS(session)
            try session.start()
            let connectionType = try session.h.sql("target57","SELECT CONNECTION_TYPE FROM performance_schema.threads WHERE PROCESSLIST_USER='apply_fixture'")
            try require(connectionType == (options.targetTransport == "unix" ? "Socket" : "SSL/TLS"),"target connection type differs: " + connectionType)
            report["target_connection_type"] = connectionType
            _ = try session.h.sql("source", "CREATE DATABASE demo CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE demo.bench(id BIGINT UNSIGNED NOT NULL PRIMARY KEY,payload VARCHAR(1024) NOT NULL,quantity BIGINT UNSIGNED NOT NULL)")
            let baseline = try session.h.boundary("source")
            let uuid = try session.h.sql("source", "SELECT @@server_uuid")
            let preparationDeadline = Date().addingTimeInterval(30)
            while try session.state("SELECT applied_file||':'||applied_position FROM state") != baseline.file + ":" + String(baseline.position) {
                try require(Date() < preparationDeadline && session.replicatorRunning(), "replicator failed preparing benchmark schema")
                Thread.sleep(forTimeInterval: 0.2)
            }
            let waited = try session.h.sql("native", "SELECT SOURCE_POS_WAIT('\(baseline.file)',\(baseline.position),30)")
            try require(waited != "NULL" && waited != "-1", "native failed preparing benchmark schema")
            let baseCounters = try counters(session)
            report["baseline"] = baseline.json
            var configurations: [String: String] = [:]
            for service in session.h.services {
                configurations[service] = try session.h.sql(service, "SELECT VERSION(),@@GLOBAL.gtid_mode,@@GLOBAL.enforce_gtid_consistency,@@GLOBAL.sync_binlog,@@GLOBAL.innodb_flush_log_at_trx_commit,@@GLOBAL.binlog_format,@@GLOBAL.binlog_row_image,@@GLOBAL.binlog_checksum; SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='demo' AND TABLE_NAME='bench'")
                try require(configurations[service]!.hasSuffix(service == "source" ? "InnoDB" : "MyISAM"), "benchmark engine differs")
            }
            report["database_configuration"] = configurations
            try nativeHealthy(session)
            let workloadHash = try runner.run(["openssl", "dgst", "-sha256", root.appendingPathComponent("docker/performance/workload.lua").path]).text.suffix(64)
            let imageHash = try session.docker(["run", "--rm", "--network", "none", "--entrypoint", "sha256sum", loadImage, "/workload.lua"]).text.prefix(64)
            try require(workloadHash == imageHash, "stale sysbench workload image; rerun without --skip-build")
            report["workload_sha256"] = String(workloadHash)

            let name = session.h.project + "-sysbench"
            loadContainer = name
            let command = ["docker", "run", "-d", "--name", name, "--network", session.h.project + "_fixture",
                           "--mount", "type=volume,src=\(session.volume),dst=/evidence,readonly", "--workdir", "/evidence/tls", loadImage,
                           "--mysql-host=source", "--mysql-user=benchmark_fixture", "--mysql-password=fixture-benchmark-only",
                           "--mysql-db=demo", "--mysql-ssl=on", "--mysql-ignore-errors=", "--db-ps-mode=disable",
                           "--events=\(options.events)", "--time=0", "--threads=\(options.threads)", "--rate=\(options.rate)",
                           "--rows-per-event=\(options.rowsPerEvent)", "--payload-bytes=\(options.payloadBytes)",
                           "--workload=\(options.workload)", "--report-interval=1", "--percentile=95", "run"]
            report["load_command"] = command
            let traceURL = output!.appendingPathComponent("samples.tsv")
            try "start_seconds\tend_seconds\tphase\tsource_before\tsource_after\tnative_applied\treplicator_applied\treplicator_rows\tnative_backlog_lower\tnative_backlog_upper\treplicator_backlog_lower\treplicator_backlog_upper\n".write(to: traceURL, atomically: true, encoding: .utf8)
            let trace = try FileHandle(forWritingTo: traceURL)
            defer { try? trace.close() }
            _ = try trace.seekToEnd()
            let clockStart = DispatchTime.now().uptimeNanoseconds
            func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - clockStart) / 1_000_000_000 }
            func count(_ service: String) throws -> Int {
                try transactionCount(session.h.sql(service, "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,'\(baseline.gtids)')"), sourceUUID: uuid)
            }
            var samples: [Sample] = []
            var loadFinished: Double?, nativeFinished: Double?, replicatorFinished: Double?
            _ = try runner.run(command)
            print("seconds  source  native  replicator  native backlog  replicator backlog")
            while true {
                let start = elapsed()
                let running = try session.docker(["inspect", name, "--format", "{{.State.Running}}"] ).text == "true"
                if !running && loadFinished == nil {
                    let exit = try session.docker(["inspect", name, "--format", "{{.State.ExitCode}}"] ).text
                    try require(exit == "0", "sysbench failed with exit \(exit); see sysbench.log")
                    loadFinished = elapsed()
                }
                let before = try count("source")
                let native = try count("native")
                let current = try counters(session)
                try require(current.lifecycle == "RUNNING", "replicator stopped during benchmark: " + current.lifecycle)
                let after = try count("source")
                let sample = Sample(phase: running ? "load" : "catch-up", startSeconds: start, endSeconds: elapsed(),
                                    sourceBefore: before, sourceAfter: after, native: native,
                                    replicator: current.transactions - baseCounters.transactions, replicatorRows: current.rows - baseCounters.rows)
                try require(before <= after && native <= after && sample.replicator <= after, "inconsistent benchmark counters")
                samples.append(sample); try trace.write(contentsOf: Data(sample.tsv.utf8))
                print(String(format: "%.1f  %d  %d  %d  %d...%d  %d...%d", sample.endSeconds, after, native, sample.replicator,
                             sample.nativeBacklogLower, sample.nativeBacklogUpper, sample.replicatorBacklogLower, sample.replicatorBacklogUpper))
                try nativeHealthy(session)
                // Resource collection is deliberately outside the counter observation window.
                let resources = try session.docker(["stats", "--no-stream", "--format", "{{json .}}"] + services).text
                try resources.write(to: output!.appendingPathComponent("resources-\(samples.count).ndjson"), atomically: true, encoding: .utf8)
                if !running {
                    try require(after == options.events, "source committed \(after) events, expected \(options.events)")
                    if native == after && nativeFinished == nil { nativeFinished = sample.endSeconds }
                    if sample.replicator == after && replicatorFinished == nil { replicatorFinished = sample.endSeconds }
                    if nativeFinished != nil && replicatorFinished != nil { break }
                    try require(elapsed() - loadFinished! < Double(options.timeoutSeconds), "replication catch-up timed out; inspect samples.tsv and diagnostics")
                } else {
                    try require(elapsed() < Double(options.timeoutSeconds), "sysbench load timed out")
                }
                Thread.sleep(forTimeInterval: max(0, Double(options.sampleSeconds) - (elapsed() - start)))
            }
            let logs = try session.docker(["logs", name])
            let totals = try sysbenchTotals(String(decoding: logs.stdout, as: UTF8.self))
            try require(totals.events == options.events, "sysbench event count differs from committed source GTIDs")
            try require(samples.last!.replicatorRows == options.events * options.rowsPerEvent, "replicator row count differs from generated workload")
            report["source_events"] = totals.events
            report["source_load_seconds"] = totals.seconds
            report["source_events_per_second"] = Double(totals.events) / totals.seconds
            report["load_exit_observed_seconds"] = loadFinished!
            report["native_completion_observed_seconds"] = nativeFinished!
            report["replicator_completion_observed_seconds"] = replicatorFinished!
            report["native_drain_observed_seconds"] = max(0, nativeFinished! - loadFinished!)
            report["replicator_drain_observed_seconds"] = max(0, replicatorFinished! - loadFinished!)
            report["samples"] = try jsonObject(samples)
            let finalBoundary = try session.h.boundary("source")
            report["final_boundary"] = finalBoundary.json
            try verifyRows(session)
            try require(session.h.boundary("source").gtids == finalBoundary.gtids, "source changed during final verification")
            try session.stopWriter()
            try require(session.state("SELECT lifecycle FROM state") == "STOPPED", "replicator did not stop cleanly")
            let diagnostic = try session.docker(["exec",session.helper,"cat","/evidence/applier.stderr"]).stdout
            guard let last = String(decoding:diagnostic,as:UTF8.self).split(separator:"\n").last,
                  let summary = try JSONSerialization.jsonObject(with:Data(last.utf8)) as? [String:Any],
                  let timings = summary["stageTimings"] as? [String:Any] else { throw LabError("missing final stage timings") }
            report["stage_timings"] = timings
            report["stage_timing_scope"] = "inclusive run-local monotonic durations, including startup and stop; nested stages overlap"
            try writeJSON(timings,to:output!.appendingPathComponent("stage-timings.json"))
            report["result"] = "passed"
        } catch {
            failure = error; report["error"] = String(describing: error)
            if output == nil { output = session.harness?.output }
        }
        if let name = loadContainer, let output {
            // Stop the generator before archiving and shutting down the appliers, even on failure.
            _ = try? session.docker(["stop", "--time", "5", name], checked: false)
            if let logs = try? session.docker(["logs", name], checked: false) {
                try? (logs.stdout + logs.stderr).write(to: output.appendingPathComponent("sysbench.log"))
            }
            _ = try? session.docker(["rm", "-f", name], checked: false)
        }
        if FileManager.default.fileExists(atPath: session.manifestURL.path) {
            do { try session.down(); report["cleanup"] = "passed" }
            catch { report["cleanup_error"] = String(describing: error); if failure == nil { failure = error } }
        }
        if let output {
            if failure != nil { report["result"] = "failed" }
            try writeJSON(report, to: output.appendingPathComponent("result.json"))
            print("Benchmark \(failure == nil ? "passed" : "failed"): \(output.path)")
        }
        if let failure { throw failure }
    }

    private static func counters(_ session: DemoSession.Session) throws -> (transactions: Int, rows: Int, lifecycle: String) {
        let parts = try session.state("SELECT transactions_applied||'|'||rows_applied||'|'||lifecycle FROM state").components(separatedBy: "|")
        guard parts.count == 3, let transactions = Int(parts[0]), let rows = Int(parts[1]) else { throw LabError("invalid benchmark SQLite counters") }
        return (transactions, rows, parts[2])
    }

    private static func prepareLoadTLS(_ session: DemoSession.Session) throws {
        // sysbench 1.0.20's MySQL driver uses these three fixed filenames in cwd.
        // Supply a fixture client certificate, signed by the existing fixture CA.
        let tls = session.h.output.appendingPathComponent("tls")
        func path(_ name: String) -> String { tls.appendingPathComponent(name).path }
        _ = try session.h.runner.run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=benchmark_fixture",
                                      "-keyout", path("client-key.pem"), "-out", path("client.csr")])
        try "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n".write(toFile: path("client.cnf"), atomically: true, encoding: .utf8)
        _ = try session.h.runner.run(["openssl", "x509", "-req", "-in", path("client.csr"), "-CA", path("ca.pem"), "-CAkey", path("ca-key.pem"),
                                      "-CAcreateserial", "-days", "2", "-sha256", "-extfile", path("client.cnf"), "-out", path("client-cert.pem")])
        for (source, destination) in [("ca.pem", "cacert.pem"), ("client-key.pem", "client-key.pem"), ("client-cert.pem", "client-cert.pem")] {
            _ = try session.docker(["cp", path(source), session.helper + ":/evidence/tls/" + destination])
        }
    }

    private static func nativeHealthy(_ session: DemoSession.Session) throws {
        let status = try session.h.status()
        try require(status["Replica_IO_Running"] == "Yes" && status["Replica_SQL_Running"] == "Yes" && status["Last_IO_Errno"] == "0" && status["Last_SQL_Errno"] == "0", "native replication stopped; see native-status.txt")
    }

    /// Compare ordered exact values in bounded pages after both appliers catch up.
    private static func verifyRows(_ session: DemoSession.Session) throws {
        var cursor: UInt64 = 0, rows = 0
        while true {
            let sql = "SELECT id,HEX(payload),quantity FROM demo.bench WHERE id>\(cursor) ORDER BY id LIMIT 1000"
            let source = try session.h.sql("source", sql)
            for service in ["native", "target57"] {
                try require(session.h.sql(service, sql) == source, "\(service) row mismatch after id \(cursor)")
            }
            let lines = source.split(separator: "\n")
            if lines.isEmpty { break }
            guard let id = lines.last?.split(separator: "\t").first, let next = UInt64(id), next > cursor else { throw LabError("invalid row verification cursor") }
            cursor = next; rows += lines.count
        }
        try writeJSON(["result": "passed", "rows_compared": rows, "comparison": "ordered id, HEX(payload), quantity; source equals native and target57"],
                      to: session.h.output.appendingPathComponent("verification.json"))
    }
}
