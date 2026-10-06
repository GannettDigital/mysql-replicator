import Foundation

/// A cached inspection is usable only while time, progress and byte headroom
/// remain within bounds. SQLite's entire budget is reserved from sampled free
/// space; relay growth is charged separately. Other writers are detected by the
/// next inspection or an I/O failure, not predicted by this accounting.
struct CapacityWindow {
    private var sequence: Int64?
    private var time: Double = 0
    private var relay: UInt64 = 0
    private var free: Int64 = 0
    private var used: Int64 = 0

    mutating func record(sequence: Int64, time: Double, relay: UInt64, free: Int64, used: Int64) {
        self.sequence = sequence; self.time = time; self.relay = relay
        self.free = free; self.used = used
    }

    func needsInspection(sequence: Int64, time: Double, relay: UInt64, incoming: Int64,
                         growth: Int64, databaseLimit: Int64, policy: StoragePolicy) -> Bool {
        guard let previous = self.sequence else { return true }
        // Reconnect can trim the unapplied relay tail. The old free-space
        // sample must be refreshed before charging growth from the new length.
        if relay < self.relay { return true }
        let relayGrowth = Int64(relay-self.relay) + incoming
        return sequence-previous >= Int64(policy.capacityCheckEveryTransactions)
            || time-self.time >= Double(policy.capacityCheckIntervalSeconds)
            || used+growth >= databaseLimit*Int64(policy.pruneAtPercent)/100
            || free-relayGrowth <= policy.minimumFreeDiskBytes+policy.maximumSQLiteBytes*2
    }
}
