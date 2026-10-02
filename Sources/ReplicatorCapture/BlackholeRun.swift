import Foundation
import ReplicatorCodec

public struct BlackholeSummary: Encodable {
    public let kind = "blackhole_summary"
    public let capture: LiveSummary
    public let rowsDecoded: Int
    public let elapsedSeconds: Double
    public let writesApplied = 0
    public let durableProgress = false
}

/// Benchmark sink: fully decode/assemble, count, then discard. This deliberately
/// accepts no target or state directory and never publishes an applied checkpoint.
public enum BlackholeRun {
    public static func run(configuration: CaptureConfiguration, password: String,
                           cancellation: CaptureCancellation = .init()) throws -> BlackholeSummary {
        guard configuration.nonBlocking == true, configuration.stopAfterTransactions == nil else {
            throw CaptureError("blackhole requires nonBlocking=true and no transaction limit, to drain a fixed backlog through EOF")
        }
        let start=DispatchTime.now().uptimeNanoseconds
        let timings=StageTimings()
        var rows=0
        let capture=try LiveInspection.run(configuration:configuration,password:password,cancellation:cancellation,
            emitEvent:{ _ in },emitTransaction:{ group in
                timings.measure("blackhole.consume") { rows += group.events.reduce(0) { $0+$1.rows.count } }
            },timings:timings,allowDDL:true)
        guard capture.pendingTransactionStart == nil, capture.download?.reachedEOF == true else {
            throw CaptureError("blackhole did not finish the complete download")
        }
        return BlackholeSummary(capture:capture,rowsDecoded:rows,
            elapsedSeconds:Double(DispatchTime.now().uptimeNanoseconds-start)/1e9)
    }
}
