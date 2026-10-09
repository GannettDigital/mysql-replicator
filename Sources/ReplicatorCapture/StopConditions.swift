import Foundation

/// Limits are inclusive and compared against completed source groups, never
/// decoded row counts or target-local GTIDs. Counts belong to one invocation.
public struct StopConditions: Encodable {
    public let stopAfterTransactions: Int?
    public let stopAfterGTIDs: String?
    private let target: GTIDSet?
    enum CodingKeys: String, CodingKey { case stopAfterTransactions,stopAfterGTIDs }
    public init(transactions: Int?, gtids: String?) throws {
        guard transactions == nil || (1...1_000_000).contains(transactions!) else { throw CaptureError("invalid stopAfterTransactions") }
        let parsed=try gtids.map(GTIDSet.init)
        guard parsed?.isEmpty != true else { throw CaptureError("stopAfterGTIDs must be a nonempty GTID set; omit it to disable") }
        stopAfterTransactions=transactions; target=parsed; stopAfterGTIDs=parsed?.canonical
    }
    public func reason(transactions: Int, executed: GTIDSet) -> String? {
        if let target,executed.covers(target) { return "gtidsSatisfied" }
        if let limit=stopAfterTransactions,transactions >= limit { return "transactionLimit" }
        return nil
    }
}
