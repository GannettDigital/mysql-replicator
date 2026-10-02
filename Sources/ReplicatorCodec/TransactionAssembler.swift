import Foundation

public struct TransactionError: Error, CustomStringConvertible {
    public enum Code: String { case sequence, unsupported, incomplete, limit, poisoned }
    public let code: Code
    public let coordinate: BinlogCoordinate
    public let transactionStart: BinlogCoordinate?
    public let lastCompleteBoundary: BinlogCoordinate?
    public let reason: String
    public var description: String { "transaction \(code.rawValue) at \(coordinate.file):\(coordinate.position): \(reason)" }
}

/// A complete source binlog group, not an applied or durable transaction.
/// Standalone statements are opaque: completion does not qualify their SQL for
/// target execution. An empty rollback has its own outcome, never a commit.
public struct CompleteTransaction: Equatable, Encodable {
    public enum Outcome: String, Encodable { case committed, rolledBack, statement }
    public let schemaVersion = 1
    public let start: BinlogCoordinate
    public let end: BinlogCoordinate
    public let gtid: SourceGTID?
    public let anonymous: Bool
    public let outcome: Outcome
    public let events: [DecodedEvent]
}

/// Serial-use, bounded assembler for physical MySQL binlog files. Feed only
/// successfully decoded events, starting at the file's FDE. No transport pseudo
/// events, automatic resynchronization, target writes or checkpoint I/O.
public final class TransactionAssembler {
    public struct Limits {
        public let events: Int
        public let wireBytes: UInt64
        public let retainedBytes: Int
        public init(events: Int = 4096, wireBytes: UInt64 = 16 * 1024 * 1024,
                    retainedBytes: Int = 32 * 1024 * 1024) {
            self.events = events; self.wireBytes = wireBytes; self.retainedBytes = retainedBytes
        }
    }
    private enum State { case idle, gtid, transaction }
    private var state: State = .idle
    private var expected: BinlogCoordinate
    private var needsFormat = true
    private var allowsPrevious = false
    private var stopped = false
    private var finished = false
    private var failed = false
    private var start: BinlogCoordinate?
    private var gtid: SourceGTID?
    private var anonymous = false
    private var events: [DecodedEvent] = []
    private var wireBytes: UInt64 = 0
    private var retainedBytes = 0
    private var statementOpen = false
    private var hasRows = false
    private let limits: Limits
    private var acceptsExcludedRanges = false
    /// Last validated complete boundary, never a durable/applied checkpoint.
    public private(set) var lastCompleteBoundary: BinlogCoordinate?
    public var pendingTransactionStart: BinlogCoordinate? { start }

    public init(file: String, limits: Limits = Limits()) throws {
        let coordinate = BinlogCoordinate(file: file, position: 4)
        guard !file.isEmpty, !file.utf8.contains(0), limits.events > 0,
              limits.wireBytes > 0, limits.retainedBytes > 0 else {
            throw TransactionError(code: .limit, coordinate: coordinate, transactionStart: nil,
                lastCompleteBoundary: nil, reason: "invalid file identity or transaction limits")
        }
        expected = coordinate; self.limits = limits
    }

    /// Live transport has already validated the dump FDE and supplied a source
    /// start boundary. Transport announcements are not physical file events.
    public convenience init(validatedStreamStart: BinlogCoordinate, allowPreviousGTIDs: Bool,
                            acceptsExcludedRanges: Bool, limits: Limits = Limits()) throws {
        try self.init(file: validatedStreamStart.file, limits: limits)
        guard validatedStreamStart.position >= 4 else { throw error(.sequence, validatedStreamStart, "invalid stream start") }
        expected = validatedStreamStart; needsFormat = false; allowsPrevious = allowPreviousGTIDs
        self.acceptsExcludedRanges = acceptsExcludedRanges
        lastCompleteBoundary = validatedStreamStart
    }

    /// A checksum-verified GTID dump heartbeat can describe skipped ranges from
    /// the caller's excluded set. Never permitted in an open group or positional
    /// mode; it is an observation, not a newly captured/applied GTID.
    public func advanceExcludedRange(to coordinate: BinlogCoordinate) throws {
        if failed { throw error(.poisoned, coordinate, "assembler failed") }
        do {
            try require(acceptsExcludedRanges && !finished && !stopped && !needsFormat && state == .idle,
                        coordinate, "excluded-range advance outside an idle GTID stream")
            try require(coordinate.file == expected.file && coordinate.position >= expected.position,
                        coordinate, "excluded-range coordinate moves backward or changes file")
            expected = coordinate; allowsPrevious = false
            // lastCompleteBoundary stays at an actually validated group/preamble.
        } catch { failed = true; events.removeAll(keepingCapacity: false); throw error }
    }

    private func error(_ code: TransactionError.Code, _ at: BinlogCoordinate, _ reason: String) -> TransactionError {
        TransactionError(code: code, coordinate: at, transactionStart: start,
            lastCompleteBoundary: lastCompleteBoundary, reason: reason)
    }
    private func require(_ condition: Bool, _ at: BinlogCoordinate, _ reason: String,
                         code: TransactionError.Code = .sequence) throws {
        if !condition { throw error(code, at, reason) }
    }

    /// Returns nil until a whole group is complete. Any failure poisons the
    /// assembler; callers must replay with new decoder/assembler instances.
    public func consume(_ event: DecodedEvent, file: String) throws -> CompleteTransaction? {
        let at = BinlogCoordinate(file: file, position: UInt64(event.offset) ?? 0)
        if failed { throw error(.poisoned, at, "assembler failed; replay from a validated boundary") }
        do {
            try require(!finished && !stopped, at, "event after end of stream")
            try require(at == expected, at, "noncontiguous file/position")
            let (endPosition, overflow) = at.position.addingReportingOverflow(UInt64(event.eventSize))
            try require(!overflow && event.eventSize >= 23 && endPosition == UInt64(event.nextPosition), at,
                        "header next-position differs from physical event end")
            let end = BinlogCoordinate(file: file, position: endPosition)
            if needsFormat {
                try require(event.control == .formatDescription && at.position == 4, at, "file must start with FDE at position 4")
                needsFormat = false; allowsPrevious = true; expected = end
                lastCompleteBoundary = end
                return nil
            }
            var completed: CompleteTransaction?
            switch event.control {
            case .formatDescription:
                throw error(.sequence, at, "unexpected FDE without rotation")
            case .previousGTIDs:
                try require(allowsPrevious && state == .idle, at, "previous-GTIDs outside file preamble")
                lastCompleteBoundary = end
            case .rotate(let destination):
                try require(state == .idle, at, "physical rotation inside incomplete transaction")
                try require(destination.file != file && destination.position == 4, at,
                            "rotation must identify a different file at position 4", code: .unsupported)
                expected = destination; needsFormat = true; allowsPrevious = false
                lastCompleteBoundary = destination
                return nil
            case .stop:
                try require(state == .idle, at, "STOP inside incomplete transaction")
                stopped = true; lastCompleteBoundary = end
            case .gtid(let identity):
                try require(state == .idle, at, "GTID before previous transaction completed")
                try require(identity.flags & ~1 == 0, at, "unknown GTID flags", code: .unsupported)
                start = at; gtid = identity; state = .gtid
                try append(event, at: at)
            case .anonymousGTID(let flags):
                try require(state == .idle, at, "anonymous GTID before previous transaction completed")
                try require(flags & ~1 == 0, at, "unknown anonymous GTID flags", code: .unsupported)
                start = at; anonymous = true; state = .gtid
                try append(event, at: at)
            case .query(let query):
                try require(query.errorCode == 0, at, "source query error requires explicit handling", code: .unsupported)
                let kind = try classify(query.sql, at: at)
                switch kind {
                case .begin:
                    try require(state != .transaction, at, "nested BEGIN")
                    if start == nil { start = at }
                    state = .transaction
                    try append(event, at: at)
                case .commit, .rollback:
                    try require(state == .transaction && !statementOpen, at, "transaction end without BEGIN or before statement end")
                    try require(kind != .rollback || !hasRows, at,
                                "rollback containing row effects requires nontransactional-source policy", code: .unsupported)
                    try append(event, at: at)
                    completed = complete(at: end, outcome: kind == .rollback ? .rolledBack : .committed)
                case .statement:
                    try require(state != .transaction, at, "query inside row transaction is not qualified", code: .unsupported)
                    if start == nil { start = at }
                    try append(event, at: at)
                    completed = complete(at: end, outcome: .statement)
                }
            case .xid:
                try require(state == .transaction && !statementOpen, at, "XID without BEGIN or before statement end")
                try append(event, at: at)
                completed = complete(at: end, outcome: .committed)
            case nil:
                try require(state == .transaction, at, "table map/rows outside BEGIN")
                if event.eventType == 19 {
                    statementOpen = true
                } else if let flags = event.rowFlags, [23,24,25,30,31,32].contains(event.eventType) {
                    try require(statementOpen && (!event.rows.isEmpty || event.replicationFiltered), at, "rows without an open mapped statement")
                    try require(flags & ~1 == 0, at, "row flags other than STMT_END are not qualified", code: .unsupported)
                    // STMT_END clears table maps, but does NOT complete a transaction.
                    statementOpen = flags & 1 == 0; hasRows = true
                } else { throw error(.unsupported, at, "unclassified transaction event") }
                try append(event, at: at)
            }
            allowsPrevious = false; expected = end
            return completed
        } catch {
            failed = true
            events.removeAll(keepingCapacity: false)
            throw error
        }
    }

    /// Strict offline EOF: a complete frame is insufficient if its transaction
    /// lacks a terminator. EOF immediately after rotation is a valid file end.
    public func finish() throws {
        if failed { throw error(.poisoned, expected, "assembler failed") }
        if finished { return }
        guard state == .idle, lastCompleteBoundary != nil else {
            failed = true; events.removeAll(keepingCapacity: false)
            throw error(.incomplete, expected, "EOF before a complete transaction or file preamble")
        }
        finished = true
    }

    private enum QueryKind { case begin, commit, rollback, statement }
    private func classify(_ sql: Data, at: BinlogCoordinate) throws -> QueryKind {
        // MySQL writes canonical BEGIN/COMMIT controls. Do not rewrite arbitrary
        // SQL, strip comments, or treat ROLLBACK TO SAVEPOINT as transaction end.
        if sql == Data("BEGIN".utf8) { return .begin }
        if sql == Data("COMMIT".utf8) { return .commit }
        if sql == Data("ROLLBACK".utf8) { return .rollback }
        let prefix = String(decoding: sql.prefix(128), as: UTF8.self).uppercased()
        let token = prefix.prefix { $0.isASCII && ($0.isLetter || $0 == "_") }
        try require(!token.isEmpty && !["BEGIN", "COMMIT", "ROLLBACK", "XA", "START", "SAVEPOINT", "RELEASE"].contains(String(token)),
                    at, "noncanonical or unsupported SQL control statement", code: .unsupported)
        return .statement
    }

    private func append(_ event: DecodedEvent, at: BinlogCoordinate) throws {
        let (wire, overflow) = wireBytes.addingReportingOverflow(UInt64(event.eventSize))
        try require(!overflow && wire <= limits.wireBytes && events.count < limits.events, at,
                    "transaction event/wire-byte limit exceeded", code: .limit)
        let cost = event.retainedByteCost
        try require(cost <= limits.retainedBytes - retainedBytes, at,
                    "transaction retained-data limit exceeded", code: .limit)
        wireBytes = wire; retainedBytes += cost; events.append(event)
    }

    private func complete(at end: BinlogCoordinate, outcome: CompleteTransaction.Outcome) -> CompleteTransaction {
        let transaction = CompleteTransaction(start: start!, end: end, gtid: gtid,
            anonymous: anonymous, outcome: outcome, events: events)
        events = []; start = nil; gtid = nil; anonymous = false; state = .idle
        statementOpen = false; hasRows = false; wireBytes = 0; retainedBytes = 0
        lastCompleteBoundary = end
        return transaction
    }
}
