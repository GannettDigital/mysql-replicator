import Foundation

/// Reuse is valid only while the same session continuously holds its WRITE lock.
/// Limits are checked at safe boundaries; an in-flight row/group is never split.
struct TableLockEpoch {
    private(set) var table: ApplyTable?
    private(set) var groups = 0
    private var started: Double = 0
    let maximumGroups: Int
    let maximumSeconds: Double
    init(maximumGroups: Int = 32, maximumSeconds: Double = 0.05) {
        self.maximumGroups = maximumGroups; self.maximumSeconds = maximumSeconds
    }
    func expired(at now: Double) -> Bool {
        table != nil && (groups >= maximumGroups || now-started >= maximumSeconds)
    }
    func canReuse(_ candidate: ApplyTable, at now: Double) -> Bool {
        table == candidate && !expired(at: now)
    }
    mutating func acquired(_ table: ApplyTable, at now: Double) {
        self.table = table; started = now; groups = 0
    }
    mutating func completedGroup() { groups += 1 }
    mutating func released() { table = nil; groups = 0 }
}
