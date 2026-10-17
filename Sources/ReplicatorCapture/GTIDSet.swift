import Foundation
import NIOCore
import ReplicatorCodec

/// Canonical GTID intervals keyed by UUID and optional tag. Bounds prevent allocation from untrusted
/// config. MySQL encodes inclusive text ends as exclusive binary ends.
public struct GTIDSet: Equatable {
    struct SID: Equatable {
        let uuid: UUID
        let tag: String?
        var intervals: [ClosedRange<UInt64>]
        var key: String { uuid.uuidString + (tag.map { ":" + $0 } ?? "") }
    }
    private(set) var sids: [SID]
    private var canonicalBytes: Int
    private static func digits(_ value: UInt64) -> Int {
        var n = value
        var count = 1
        while n >= 10 {
            n /= 10
            count += 1
        }
        return count
    }
    private static func bytes(_ range: ClosedRange<UInt64>) -> Int {
        digits(range.lowerBound) + (range.lowerBound == range.upperBound ? 0 : 1 + digits(range.upperBound))
    }
    public init(_ text: String) throws {
        guard text.utf8.count <= 1024 * 1024 else { throw CaptureError("GTID set exceeds 1 MiB") }
        var result: [SID] = []
        if !text.isEmpty {
            for entry in text.split(separator: ",", omittingEmptySubsequences: false) {
                let fields = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(
                    separator: ":", omittingEmptySubsequences: false)
                guard fields.count >= 2, let uuid = UUID(uuidString: String(fields[0])) else {
                    throw CaptureError("invalid GTID SID")
                }
                var tag: String?
                var ranges: [ClosedRange<UInt64>] = []
                func finish() throws {
                    guard !ranges.isEmpty, result.count < 64,
                        !result.contains(where: { $0.uuid == uuid && $0.tag == tag })
                    else { throw CaptureError("empty, duplicate or excessive GTID identity") }
                    ranges.sort { $0.lowerBound < $1.lowerBound }
                    var merged: [ClosedRange<UInt64>] = []
                    for range in ranges {
                        if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                            merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                        } else {
                            merged.append(range)
                        }
                    }
                    result.append(SID(uuid: uuid, tag: tag, intervals: merged))
                    ranges = []
                }
                for raw in fields.dropFirst() {
                    let field = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let first = field.utf8.first, !(48...57).contains(first) {
                        if !ranges.isEmpty {
                            try finish()
                        } else if tag != nil {
                            throw CaptureError("GTID tag without intervals")
                        }
                        tag = try SourceGTID.normalizedTag(field)
                    } else {
                        let bounds = field.split(separator: "-", omittingEmptySubsequences: false)
                        guard (1...2).contains(bounds.count),
                            bounds.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
                            let low = UInt64(bounds[0]), let high = UInt64(bounds.last!), low > 0, low <= high,
                            high < UInt64(Int64.max), ranges.count < 4096
                        else { throw CaptureError("invalid GTID interval") }
                        ranges.append(low...high)
                    }
                }
                try finish()
            }
        }
        sids = result.sorted { $0.key < $1.key }
        canonicalBytes =
            max(0, sids.count - 1)
            + sids.reduce(0) { total, sid in
                total + 36 + (sid.tag.map { 1 + $0.utf8.count } ?? 0)
                    + sid.intervals.reduce(0) { $0 + 1 + Self.bytes($1) }
            }
        guard canonicalBytes <= 1024 * 1024 else { throw CaptureError("GTID set exceeds 1 MiB") }
    }
    public var isEmpty: Bool { sids.isEmpty }
    public var canonical: String {
        var entries: [String] = []
        var previous: UUID?
        for sid in sids {
            let ranges = sid.intervals.map {
                $0.lowerBound == $0.upperBound ? String($0.lowerBound) : "\($0.lowerBound)-\($0.upperBound)"
            }.joined(separator: ":")
            let tail = (sid.tag.map { ":" + $0 } ?? "") + ":" + ranges
            if previous == sid.uuid {
                entries[entries.count - 1] += tail
            } else {
                entries.append(sid.uuid.uuidString.lowercased() + tail)
            }
            previous = sid.uuid
        }
        return entries.joined(separator: ",")
    }

    public func contains(sid: String, sequence: String, tag: String? = nil) -> Bool {
        guard let uuid = UUID(uuidString: sid), let n = UInt64(sequence) else { return false }
        return sids.first { $0.uuid == uuid && $0.tag == tag?.lowercased() }?.intervals.contains { $0.contains(n) }
            ?? false
    }
    public func covers(_ other: GTIDSet) -> Bool {
        other.sids.allSatisfy { required in
            guard let stored = sids.first(where: { $0.uuid == required.uuid && $0.tag == required.tag }) else {
                return false
            }
            return required.intervals.allSatisfy { range in
                stored.intervals.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
            }
        }
    }
    func union(_ other: GTIDSet) throws -> GTIDSet {
        let ids = Set((sids + other.sids).map(\.key)).sorted()
        let entries = ids.map { key -> String in
            let ranges = (sids + other.sids).filter { $0.key == key }.flatMap(\.intervals).sorted {
                $0.lowerBound < $1.lowerBound
            }
            var merged: [ClosedRange<UInt64>] = []
            for range in ranges {
                if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            return key + ":" + merged.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ":")
        }
        return try GTIDSet(entries.joined(separator: ","))
    }
    public func contains(_ id: SourceGTID) -> Bool { contains(sid: id.sid, sequence: id.sequence, tag: id.tag) }
    public mutating func include(_ id: SourceGTID) throws {
        try include(sid: id.sid, sequence: id.sequence, tag: id.tag)
    }
    public mutating func include(sid: String, sequence: String, tag: String? = nil) throws {
        let tag = try tag.map { try SourceGTID.normalizedTag($0) }
        guard let uuid = UUID(uuidString: sid), !sequence.isEmpty,
            sequence.utf8.allSatisfy({ (48...57).contains($0) }),
            let n = UInt64(sequence), n > 0, n < UInt64(Int64.max)
        else {
            throw CaptureError("invalid observed GTID")
        }
        guard let index = sids.firstIndex(where: { $0.uuid == uuid && $0.tag == tag }) else {
            let size =
                canonicalBytes + (sids.isEmpty ? 0 : 1) + 37 + (tag.map { 1 + $0.utf8.count } ?? 0) + Self.digits(n)
            guard sids.count < 64, size <= 1024 * 1024 else { throw CaptureError("GTID set limit exceeded") }
            let key = uuid.uuidString + (tag.map { ":" + $0 } ?? "")
            let position = sids.firstIndex { $0.key > key } ?? sids.count
            sids.insert(SID(uuid: uuid, tag: tag, intervals: [n...n]), at: position)
            canonicalBytes = size
            return
        }
        // Find the first interval whose end reaches n. Usually this is an
        // append to the final interval; no text serialization or sorting.
        var low = 0
        var high = sids[index].intervals.count
        while low < high {
            let mid = low + (high - low) / 2
            if sids[index].intervals[mid].upperBound < n { low = mid + 1 } else { high = mid }
        }
        if low < sids[index].intervals.count, sids[index].intervals[low].contains(n) { return }
        var start = low
        var end = low
        var lower = n
        var upper = n
        if low > 0, sids[index].intervals[low - 1].upperBound + 1 == n {
            start -= 1
            lower = sids[index].intervals[start].lowerBound
        }
        if low < sids[index].intervals.count, sids[index].intervals[low].lowerBound == n + 1 {
            end += 1
            upper = sids[index].intervals[low].upperBound
        }
        let replacement = lower...upper
        let removedBytes = sids[index].intervals[start..<end].reduce(0) { $0 + 1 + Self.bytes($1) }
        let size = canonicalBytes - removedBytes + 1 + Self.bytes(replacement)
        guard sids[index].intervals.count - (end - start) + 1 <= 4096,
            size <= 1024 * 1024
        else { throw CaptureError("GTID set limit exceeded") }
        // Check all bounds before mutation, so a rejected update is atomic.
        if end - start == 1 {
            sids[index].intervals[start] = replacement
        } else {
            sids[index].intervals.replaceSubrange(start..<end, with: [replacement])
        }
        canonicalBytes = size
    }
    func encoded() -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        let tagged = sids.contains { $0.tag != nil }
        let header = tagged ? (UInt64(1) << 56) | (UInt64(sids.count) << 8) | 1 : UInt64(sids.count)
        buffer.writeInteger(header, endianness: .little)
        for sid in sids {
            var uuid = sid.uuid.uuid
            withUnsafeBytes(of: &uuid) { buffer.writeBytes($0) }
            if tagged {
                let bytes = Array((sid.tag ?? "").utf8)
                buffer.writeInteger(UInt8(bytes.count << 1))  // native varint, length <= 32
                buffer.writeBytes(bytes)
            }
            buffer.writeInteger(UInt64(sid.intervals.count), endianness: .little)
            for range in sid.intervals {
                buffer.writeInteger(range.lowerBound, endianness: .little)
                buffer.writeInteger(range.upperBound + 1, endianness: .little)
            }
        }
        return buffer
    }
    init(encoded data: Data) throws {
        guard data.count <= 17 * 1024 * 1024 else { throw CaptureError("encoded GTID set exceeds limit") }
        let b = Array(data)
        var at = 0
        func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= b.count - at else { throw CaptureError("truncated GTID set") }
            defer { at += n }
            return Array(b[at..<at + n])
        }
        func number() throws -> UInt64 {
            try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }
        func variable() throws -> UInt64 {
            let first = try take(1)[0]
            var ones = 0
            while ones < 8 && first & (1 << ones) != 0 { ones += 1 }
            if ones == 8 { return try number() }
            var n = UInt64(first)
            for (i, v) in try take(ones).enumerated() { n |= UInt64(v) << (8 * (i + 1)) }
            return n >> (ones + 1)
        }
        let header = try number()
        let format = header >> 56
        guard format <= 1, format == 0 || header & 255 == 1 else {
            throw CaptureError("unknown or invalid GTID set encoding")
        }
        let count = format == 1 ? (header >> 8) & 0xffff_ffff_ffff : header
        guard count <= 64 else { throw CaptureError("previous-GTID SID limit exceeded") }
        var entries: [String] = []
        for _ in 0..<count {
            let u = try take(16)
            let uuid = UUID(
                uuid: (
                    u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]
                ))
            var entry = uuid.uuidString.lowercased()
            if format == 1 {
                let length = try variable()
                guard length <= 32 else { throw CaptureError("GTID tag exceeds 32 bytes") }
                if length > 0 {
                    entry += ":" + (try SourceGTID.normalizedTag(String(decoding: take(Int(length)), as: UTF8.self)))
                }
            }
            let ranges = try number()
            guard (1...4096).contains(ranges) else { throw CaptureError("previous-GTID interval limit exceeded") }
            var last: UInt64 = 0
            for _ in 0..<ranges {
                let low = try number()
                let high = try number()
                guard low > last, high > low, high <= UInt64(Int64.max) else {
                    throw CaptureError("invalid previous-GTID interval")
                }
                entry += ":\(low)-\(high-1)"
                last = high
            }
            entries.append(entry)
        }
        guard at == b.count else { throw CaptureError("trailing previous-GTID bytes") }
        try self.init(entries.joined(separator: ","))
    }

}

extension GTIDSet {
    /// Interval arithmetic avoids allocating one entry per transaction. A single
    /// replay endpoint can estimate the prefix through that number without
    /// changing the exact stop condition. Counts saturate at UInt64.max.
    public func remainingTransactions(after completed: GTIDSet, throughEndpoints: Bool = false) -> UInt64 {
        var total: UInt64 = 0
        for sid in sids {
            let done = completed.sids.first { $0.uuid == sid.uuid && $0.tag == sid.tag }?.intervals ?? []
            let wanted = throughEndpoints ? [UInt64(1)...sid.intervals.last!.upperBound] : sid.intervals
            var j = 0
            for range in wanted {
                var missing = range.upperBound - range.lowerBound + 1
                while j < done.count && done[j].upperBound < range.lowerBound { j += 1 }
                var k = j
                while k < done.count && done[k].lowerBound <= range.upperBound {
                    missing -= min(range.upperBound, done[k].upperBound) - max(range.lowerBound, done[k].lowerBound) + 1
                    k += 1
                }
                let sum = total.addingReportingOverflow(missing)
                total = sum.overflow ? .max : sum.partialValue
            }
        }
        return total
    }
}
