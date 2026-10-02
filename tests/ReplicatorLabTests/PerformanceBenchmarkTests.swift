import XCTest
@testable import ReplicatorLabCore

final class PerformanceBenchmarkTests: XCTestCase {
    func testDecoderReportSortsBySelfTimeAndComputesMeanFromCalls() throws {
        let report = try PerformanceBenchmark.decoderProfile([
            "decode.parent":["count":2,"failures":0,"seconds":0.010,"selfSeconds":0.001,"maximumSeconds":0.007],
            "decode.child":["count":4,"failures":1,"seconds":0.009,"selfSeconds":0.009,"maximumSeconds":0.005],
            "capture.decode":["count":2,"failures":0,"seconds":0.01,"selfSeconds":0,"maximumSeconds":0.007]])
        let lines=report.split(separator:"\n")
        XCTAssertEqual(lines.count,3)
        XCTAssertEqual(lines[1],"decode.child\t4\t1\t9.000\t9.000\t2250.000\t5000.000")
        XCTAssertEqual(lines[2],"decode.parent\t2\t0\t10.000\t1.000\t5000.000\t7000.000")
    }

    func testApplierReportExcludesOtherWorkersAndSortsBySelfTime() throws {
        let sample: [String:Any] = ["count":2,"failures":1,"seconds":0.004,"selfSeconds":0.003,"maximumSeconds":0.003]
        let report = try PerformanceBenchmark.applierProfile([
            "apply.detail.relay.metadata":sample,"target.sql":sample,"decode.parent":sample,
            "download.pack":sample,"capture.decode":sample,"pipeline.enqueue":sample])
        let lines=report.split(separator:"\n")
        XCTAssertEqual(lines.count,3)
        XCTAssertEqual(lines[1],"apply.detail.relay.metadata\t2\t1\t4.000\t3.000\t2000.000\t3000.000")
        XCTAssertTrue(lines[2].hasPrefix("target.sql\t"))
    }

    let sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    func testServerCounterDeltasRejectResetsMissingCountersAndThreadChanges() throws {
        typealias M = ServerWorkCounters.Metric
        typealias S = ServerWorkCounters.Snapshot
        let before=S(threadIDs:[7],metrics:["table.insert":M(key:"table.insert",count:2,picoseconds:20)])
        let after=S(threadIDs:[7],metrics:["table.insert":M(key:"table.insert",count:12,picoseconds:120),"prepared.new":M(key:"prepared.new",count:10,picoseconds:50)])
        let delta=try ServerWorkCounters.delta(before:before,after:after)
        XCTAssertEqual(delta["table.insert"],M(key:"table.insert",count:10,picoseconds:100))
        XCTAssertEqual(delta["prepared.new"]?.count,10)
        XCTAssertThrowsError(try ServerWorkCounters.delta(before:before,after:S(threadIDs:[8],metrics:after.metrics)))
        XCTAssertThrowsError(try ServerWorkCounters.delta(before:before,after:S(threadIDs:[7],metrics:[:])))
        XCTAssertThrowsError(try ServerWorkCounters.delta(before:after,after:before))
    }

    func testCommittedGTIDCountIncludesDisjointIntervals() throws {
        XCTAssertEqual(try PerformanceBenchmark.transactionCount("", sourceUUID: sid), 0)
        XCTAssertEqual(try PerformanceBenchmark.transactionCount(sid + ":5:8-10:20-25", sourceUUID: sid), 10)
        XCTAssertEqual(try PerformanceBenchmark.transactionCount(sid.uppercased() + ":1-1000\n", sourceUUID: sid), 1000)
    }

    func testInvalidGTIDsCannotProducePlausibleThroughput() {
        for value in [sid, sid + ":0", sid + ":2-1", sid + ":1-3:3-5", sid + ":1-2-3", sid + ":1:",
                      sid + ":1,bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee:1", sid + ":9223372036854775808"] {
            XCTAssertThrowsError(try PerformanceBenchmark.transactionCount(value, sourceUUID: sid), value)
        }
        XCTAssertThrowsError(try PerformanceBenchmark.transactionCount(sid + ":1", sourceUUID: "another-source"))
    }

    func testCounterSamplesExpressPollingUncertainty() {
        let sample = PerformanceBenchmark.Sample(phase: "load", startSeconds: 1, endSeconds: 2,
            sourceBefore: 100, sourceAfter: 120, native: 110, replicator: 80, replicatorRows: 160)
        XCTAssertEqual(sample.nativeBacklogLower, 0)
        XCTAssertEqual(sample.nativeBacklogUpper, 10)
        XCTAssertEqual(sample.replicatorBacklogLower, 20)
        XCTAssertEqual(sample.replicatorBacklogUpper, 40)
    }

    func testLoadSummaryRequiresActualCompletedEventsAndFiniteTime() throws {
        let log = "General statistics:\n    total time:                          10.0031s\n    total number of events:              1000\n"
        let result = try PerformanceBenchmark.sysbenchTotals(log)
        XCTAssertEqual(result.events, 1000)
        XCTAssertEqual(result.seconds, 10.0031)
        for invalid in ["FATAL: connection failed", log + log, log.replacingOccurrences(of: "10.0031", with: "nan"),
                        log.replacingOccurrences(of: "10.0031", with: "0")] {
            XCTAssertThrowsError(try PerformanceBenchmark.sysbenchTotals(invalid))
        }
    }

    func testBenchmarkOptionsRejectUnboundedOrUnsupportedRuns() throws {
        for args in [["--insert-rows","0"], ["--insert-rows","129"], ["--overlap-preparation","yes"], ["--flush-on-table-change","yes"], ["--explicit-table-locks","yes"], ["--tables","0"], ["--tables","33"], ["--table-run","0"], ["--table-distribution","hot80"], ["--table-distribution","random"], ["--events", "0"], ["--events", "-1"], ["--threads", "33"], ["--rate", "-1"],
                     ["--workload", "oltp"], ["--rows-per-event", "101"], ["--payload-bytes", "1025"],
                     ["--sample-seconds", "0"], ["--timeout", "0"], ["--events", "1000", "--rate", "1"],
                     ["--events", "1", "--threads", "2"], ["--host", "production"], ["--events"],
                     ["--target-transport","tcp"], ["--target-transport"],
                     ["--batch-transactions","0"], ["--batch-transactions","257"]] {
            XCTAssertThrowsError(try PerformanceOptions(arguments: args), String(describing: args))
        }
        let options = try PerformanceOptions(arguments: ["--events", "300", "--rate", "0", "--workload", "mixed", "--threads", "4", "--skip-build"])
        XCTAssertFalse(try PerformanceOptions(arguments:[]).explicitTableLocks)
        XCTAssertTrue(try PerformanceOptions(arguments:["--explicit-table-locks","on"]).explicitTableLocks)
        let multi = try PerformanceOptions(arguments:["--tables","8","--table-distribution","hot80","--table-run","16"])
        XCTAssertEqual(multi.tableNames,["bench","bench_1","bench_2","bench_3","bench_4","bench_5","bench_6","bench_7"])
        XCTAssertFalse(try PerformanceOptions(arguments:["--overlap-preparation","off"]).overlapPreparation)
        XCTAssertTrue(try PerformanceOptions(arguments:["--flush-on-table-change","on"]).flushOnTableChange)
        XCTAssertEqual(try PerformanceOptions(arguments:["--insert-rows","1"]).insertRows,1)
        XCTAssertEqual(multi.tableRun,16)
        XCTAssertEqual(multi.tableDistribution,"hot80")
        XCTAssertEqual(options.events, 300)
        XCTAssertEqual(options.rate, 0)
        XCTAssertEqual(options.workload, "mixed")
        XCTAssertFalse(options.build)
        XCTAssertEqual(options.targetTransport,"tcp-tls")
        XCTAssertEqual(options.batchTransactions,32)
        XCTAssertTrue(options.applierProfiling)
        XCTAssertFalse(try PerformanceOptions(arguments:["--applier-profile","off"]).applierProfiling)
        XCTAssertTrue(try PerformanceOptions(arguments:["--applier-profile","on"]).applierProfiling)
        XCTAssertThrowsError(try PerformanceOptions(arguments:["--applier-profile","yes"]))
        XCTAssertThrowsError(try PerformanceOptions(arguments:["--applier-profile"]))
        XCTAssertTrue(options.decoderProfiling)
        XCTAssertFalse(try PerformanceOptions(arguments:["--decoder-profile","off"]).decoderProfiling)
        XCTAssertTrue(try PerformanceOptions(arguments:["--decoder-profile","on"]).decoderProfiling)
        XCTAssertThrowsError(try PerformanceOptions(arguments:["--decoder-profile","yes"]))
        XCTAssertThrowsError(try PerformanceOptions(arguments:["--decoder-profile"]))
        XCTAssertEqual(try PerformanceOptions(arguments:["--batch-transactions","1"]).batchTransactions,1)
        for transport in ["tcp-tls","unix-tls","unix"] {
            XCTAssertEqual(try PerformanceOptions(arguments:["--target-transport",transport]).targetTransport,transport)
        }
    }
}
