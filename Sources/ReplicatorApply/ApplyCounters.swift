import Foundation
import ReplicatorCodec

/// Totals cover completed source groups, including filtered or skipped groups.
/// Row counts cover acknowledged writes only. They do not infer an uncertain write.
public struct ApplyCounters: Codable, Equatable {
    public var sinceTransaction: Int64 = 0
    public var insertRows: Int64 = 0
    public var updateRows: Int64 = 0
    public var deleteRows: Int64 = 0
    public var dmlTransactions: Int64 = 0
    public var filteredTransactions: Int64 = 0
    public var policySkippedTransactions: Int64 = 0
    public var errorSkippedTransactions: Int64 = 0
    public var processedBinlogBytes: Int64 = 0
    public var processedEvents: Int64 = 0

    enum Outcome { case applied, filtered, policySkipped, errorSkipped }
    mutating func complete(_ group: CompleteTransaction, rows: Int, outcome: Outcome = .applied) {
        processedBinlogBytes += group.events.reduce(0) { $0 + Int64($1.eventSize) }
        processedEvents += Int64(group.events.count)
        switch outcome {
        case .filtered: filteredTransactions += 1
        case .policySkipped: policySkippedTransactions += 1
        case .errorSkipped: errorSkippedTransactions += 1
        case .applied:
            if rows > 0 { dmlTransactions += 1 }
            var left = rows
            for event in group.events where !event.replicationFiltered {
                for row in event.rows where left > 0 {
                    switch row.operation {
                    case "insert": insertRows += 1
                    case "update": updateRows += 1
                    case "delete": deleteRows += 1
                    default: break
                    }
                    left -= 1
                }
            }
        }
    }
    var values: [String] {
        [
            sinceTransaction, insertRows, updateRows, deleteRows, dmlTransactions, filteredTransactions,
            policySkippedTransactions, errorSkippedTransactions, processedBinlogBytes, processedEvents,
        ].map(String.init)
    }
    init(sinceTransaction: Int64 = 0) { self.sinceTransaction = sinceTransaction }
    init(saved: [String?]) throws {
        let n = saved.compactMap { $0.flatMap(Int64.init) }
        try require(n.count == 10 && n.allSatisfy { $0 >= 0 }, "invalid saved statistics")
        sinceTransaction = n[0]
        insertRows = n[1]
        updateRows = n[2]
        deleteRows = n[3]
        dmlTransactions = n[4]
        filteredTransactions = n[5]
        policySkippedTransactions = n[6]
        errorSkippedTransactions = n[7]
        processedBinlogBytes = n[8]
        processedEvents = n[9]
    }
}
