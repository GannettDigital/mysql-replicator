import Foundation
import ReplicatorCapture

public struct SourceReconnectPolicy: Decodable {
    public var enabled = true
    public var initialDelaySeconds = 1
    public var maximumDelaySeconds = 30
    /// Zero retries indefinitely. The budget resets only after applied progress.
    public var maximumAttempts = 0
    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, initialDelaySeconds, maximumDelaySeconds, maximumAttempts }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy:CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? enabled
        initialDelaySeconds = try c.decodeIfPresent(Int.self,forKey:.initialDelaySeconds) ?? initialDelaySeconds
        maximumDelaySeconds = try c.decodeIfPresent(Int.self,forKey:.maximumDelaySeconds) ?? maximumDelaySeconds
        maximumAttempts = try c.decodeIfPresent(Int.self,forKey:.maximumAttempts) ?? maximumAttempts
    }
    func validate() throws {
        try require((1...300).contains(initialDelaySeconds) && (initialDelaySeconds...300).contains(maximumDelaySeconds)
                    && (0...10000).contains(maximumAttempts),"invalid source reconnect policy")
    }
}

struct SourceRetryState {
    let policy: SourceReconnectPolicy
    private(set) var attempts = 0
    private var consecutive = 0
    private var lastApplied: Int?
    private var delay = 0
    init(policy: SourceReconnectPolicy) { self.policy = policy }
    mutating func nextDelay(appliedTransactions: Int) throws -> Int {
        if lastApplied != appliedTransactions { consecutive = 0; delay = policy.initialDelaySeconds }
        try require(policy.enabled && (policy.maximumAttempts == 0 || consecutive < policy.maximumAttempts),"source reconnect attempts exhausted")
        lastApplied = appliedTransactions; consecutive += 1; attempts += 1
        let result = delay
        delay = min(policy.maximumDelaySeconds,delay*2)
        return result
    }
    static func wait(seconds: Int, cancellation: CaptureCancellation) {
        let deadline = ProcessInfo.processInfo.systemUptime+Double(seconds)
        while !cancellation.isCancelled {
            let remaining = deadline-ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            Thread.sleep(forTimeInterval:min(0.05,remaining))
        }
    }
}
