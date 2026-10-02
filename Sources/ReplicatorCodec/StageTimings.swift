import Foundation

/// Worker-local, monotonic measurements. Never share an instance across threads;
/// merge snapshots only after workers have joined. Parallel worker times overlap.
/// `seconds` includes nested stages; `selfSeconds` excludes them. These are
/// elapsed durations (including I/O), not CPU samples or the entire run lifetime.
public final class StageTimings {
    public struct Sample: Codable {
        public var count: UInt64 = 0
        public var failures: UInt64 = 0
        public var seconds: Double = 0
        public var selfSeconds: Double = 0
        public var maximumSeconds: Double = 0
    }
    private var samples: [String: Sample] = [:]
    private var childNanoseconds: [UInt64] = []
    private let clock: () -> UInt64
    public init() { clock = { DispatchTime.now().uptimeNanoseconds } }
    init(clock: @escaping () -> UInt64) { self.clock = clock }
    public var snapshot: [String: Sample] { samples }
    /// Import a worker's final snapshot only after that worker has joined.
    /// Times on separate workers overlap and are not children of this worker.
    public func merge(_ other: [String:Sample]) {
        for (name,value) in other {
            var sample = samples[name] ?? Sample()
            sample.count += value.count; sample.failures += value.failures
            sample.seconds += value.seconds; sample.selfSeconds += value.selfSeconds
            sample.maximumSeconds = max(sample.maximumSeconds,value.maximumSeconds)
            samples[name] = sample
        }
    }
    /// Import a disjoint native child while its enclosing Swift timer is active.
    /// Native stages run at most once per feed, so their duration is also max.
    func recordNative(_ stage: String, count: UInt64, failures: UInt64, nanoseconds: UInt64) {
        guard count != 0 else { return }
        let seconds=Double(nanoseconds)/1_000_000_000
        var sample=samples[stage] ?? Sample()
        sample.count += count; sample.failures += failures
        sample.seconds += seconds; sample.selfSeconds += seconds
        sample.maximumSeconds=max(sample.maximumSeconds,seconds)
        samples[stage]=sample
        if !childNanoseconds.isEmpty { childNanoseconds[childNanoseconds.count-1] += nanoseconds }
    }
    public func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = clock()
        childNanoseconds.append(0)
        var failed = true
        defer {
            let nanoseconds = clock() - start
            let children = childNanoseconds.removeLast()
            if !childNanoseconds.isEmpty { childNanoseconds[childNanoseconds.count-1] += nanoseconds }
            let elapsed = Double(nanoseconds) / 1_000_000_000
            var sample = samples[stage] ?? Sample()
            sample.count += 1; sample.failures += failed ? 1 : 0
            sample.seconds += elapsed; sample.maximumSeconds = max(sample.maximumSeconds, elapsed)
            // Native and Swift clocks can round at different resolutions.
            sample.selfSeconds += Double(nanoseconds >= children ? nanoseconds-children : 0) / 1_000_000_000
            samples[stage] = sample
        }
        let result = try body()
        failed = false
        return result
    }
}
