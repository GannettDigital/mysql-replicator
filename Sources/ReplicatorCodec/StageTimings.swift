import Foundation

/// Run-local, monotonic measurements. Call from the serial capture/apply thread.
/// Stages are inclusive: nested stages must not be added together as wall time.
public final class StageTimings {
    public struct Sample: Codable {
        public var count: UInt64 = 0
        public var failures: UInt64 = 0
        public var seconds: Double = 0
        public var maximumSeconds: Double = 0
    }
    private var samples: [String: Sample] = [:]
    public init() {}
    public var snapshot: [String: Sample] { samples }
    public func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        var failed = true
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            var sample = samples[stage] ?? Sample()
            sample.count += 1; sample.failures += failed ? 1 : 0
            sample.seconds += elapsed; sample.maximumSeconds = max(sample.maximumSeconds, elapsed)
            samples[stage] = sample
        }
        let result = try body()
        failed = false
        return result
    }
}
