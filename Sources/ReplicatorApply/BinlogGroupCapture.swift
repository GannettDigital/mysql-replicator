import Foundation
import ReplicatorCapture
import ReplicatorCodec

/// Consumer-owned raw references for one source group. The same events have
/// already been appended to the relay; no target connection is used here.
struct BinlogGroupCapture {
    let maximumRawBytes: Int
    private var format: Data?
    private var frames: [Data] = []
    private var offsets: [String] = []
    private var bytes = 0
    private var failure: String?

    init(maximumRawBytes: Int) { self.maximumRawBytes = maximumRawBytes }

    mutating func resetGroup() {
        frames = []
        offsets = []
        bytes = 0
        failure = nil
    }
    mutating func append(_ record: LiveRecord) {
        let raw = record.rawBytes ?? record.rawBase64.flatMap { Data(base64Encoded: $0) }
        if record.kind == "formatContext" {
            resetGroup()
            format = raw
            return
        }
        guard record.kind == "event", let event = record.event else { return }
        if case .gtid = event.control { resetGroup() }
        guard [19, 30, 31, 32].contains(Int(event.eventType)) else { return }
        guard failure == nil else { return }
        guard let raw, raw.count <= maximumRawBytes - bytes else {
            failure = "BINLOG group has missing raw events or exceeds the raw-event byte limit"
            frames = []
            offsets = []
            return
        }
        frames.append(raw)
        offsets.append(event.offset)
        bytes += raw.count
    }
    func prepare(
        _ group: CompleteTransaction, mutations: [Mutation], maximumPacketBytes: Int,
        transactional: Bool, preserveSourceGTIDs: Bool
    ) throws -> BinlogEventProgram {
        if let failure { throw ApplyError(failure) }
        guard let format else { throw ApplyError("BINLOG group lacks a source format description") }
        try require(
            !group.events.contains { $0.replicationFiltered },
            "BINLOG transport cannot apply a partially filtered source group; use SQL transport")
        try require(
            !mutations.contains { $0.table.columns.contains { $0.isGenerated } },
            "BINLOG transport has not implemented generated-column mapping; use SQL transport")
        let rowEvents = group.events.filter { [19, 30, 31, 32].contains(Int($0.eventType)) }
        try require(rowEvents.map(\.offset) == offsets, "BINLOG raw events differ from the decoded source group")
        try require(
            group.events.allSatisfy { [2, 16, 19, 29, 30, 31, 32, 33, 42].contains(Int($0.eventType)) },
            "source group contains an event not supported by BINLOG transport")
        return try BinlogEventProgram(
            format: format, events: frames,
            maximumPacketBytes: maximumPacketBytes, maximumRawBytes: maximumRawBytes,
            transactionalTarget: transactional, preserveSourceGTIDs: preserveSourceGTIDs)
    }
}
