import Foundation

/// Outer relay framing remains two UInt32 LE lengths, metadata, then raw event.
/// Binary metadata v1: "RMD", version byte, kind byte, UInt64 LE source position,
/// UInt16 LE filename byte count, UTF-8 filename. Legacy metadata starts with '{'.
struct RelayMetadata: Codable, Equatable {
    let kind: String
    let file: String
    let observedPosition: String
    private static let kinds = ["event", "rotationAnnouncement", "formatContext", "heartbeat"]

    private func validatedPosition() throws -> UInt64 {
        try require(Self.kinds.contains(kind),"unknown relay record kind")
        try require(!file.isEmpty && file.utf8.count <= 255 && !file.utf8.contains(0),"invalid relay source filename")
        guard let position=UInt64(observedPosition), String(position) == observedPosition else { throw ApplyError("invalid relay source position") }
        return position
    }
    func encoded() throws -> Data {
        let position=try validatedPosition()
        var output=Data([0x52,0x4d,0x44,1,UInt8(Self.kinds.firstIndex(of:kind)!+1)])
        output.reserveCapacity(15+file.utf8.count)
        Self.append(position,to:&output)
        Self.append(UInt16(file.utf8.count),to:&output)
        output.append(contentsOf:file.utf8)
        return output
    }
    static func decoded(_ data: Data) throws -> (RelayMetadata,Int) {
        if data.first == 0x7b {
            let value=try JSONDecoder().decode(Self.self,from:data)
            _ = try value.validatedPosition()
            return (value,0)
        }
        try require(data.count >= 15 && data.prefix(3) == Data([0x52,0x4d,0x44]),"invalid binary relay metadata header")
        try require(data[3] == 1,"unsupported binary relay metadata version")
        let kind=Int(data[4])
        try require((1...kinds.count).contains(kind),"unknown binary relay record kind")
        let length=Int(read(data,at:13,as:UInt16.self))
        try require(data.count == 15+length,"binary relay filename length differs")
        guard let file=String(data:data.dropFirst(15),encoding:.utf8) else { throw ApplyError("invalid relay filename UTF-8") }
        let value=RelayMetadata(kind:kinds[kind-1],file:file,observedPosition:String(read(data,at:5,as:UInt64.self)))
        _ = try value.validatedPosition()
        return (value,1)
    }
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little=value.littleEndian
        withUnsafeBytes(of:&little) { data.append(contentsOf:$0) }
    }
    // Byte-wise reads support unaligned frame starts on every architecture.
    static func read<T: FixedWidthInteger>(_ data: Data, at offset: Int, as: T.Type) -> T {
        (0..<MemoryLayout<T>.size).reduce(T(0)) { $0 | T(data[offset+$1]) << (8*$1) }
    }
}

/// Read-only evidence inspection. This decodes framing and metadata, not binlog
/// payloads or CRCs, and never publishes or changes replication progress.
public enum RelayInspection {
    public struct Record: Encodable {
        public let relayOffset: UInt64
        public let relayEnd: UInt64
        public let metadataVersion: Int
        public let kind: String
        public let file: String
        public let observedPosition: String
        public let eventBytes: Int
        public let rawBase64: String?
    }
    public static func inspect(file: URL, includeRaw: Bool = false, endOffset: UInt64? = nil, emit: (Record) throws -> Void) throws {
        let handle=try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        var offset: UInt64=0
        func read(_ count: Int) throws -> Data {
            var data=Data()
            while data.count < count {
                guard let part=try handle.read(upToCount:count-data.count), !part.isEmpty else { break }
                data.append(part)
            }
            return data
        }
        while true {
            if let endOffset, offset == endOffset { return }
            try require(endOffset == nil || offset < endOffset!,"relay inspection exceeded requested boundary")
            let header=try read(8)
            if header.isEmpty {
                try require(endOffset == nil,"relay ended before requested boundary")
                return
            }
            try require(header.count == 8,"truncated relay frame header at byte \(offset)")
            let metadataLength=Int(RelayMetadata.read(header,at:0,as:UInt32.self))
            let eventLength=Int(RelayMetadata.read(header,at:4,as:UInt32.self))
            // Legacy JSON can escape every byte of a 255-byte filename. Bounds
            // are checked before allocation, independent of untrusted lengths.
            try require((1...4096).contains(metadataLength) && (1...16*1024*1024).contains(eventLength),"invalid relay frame lengths at byte \(offset)")
            let metadata=try read(metadataLength), raw=try read(eventLength)
            try require(metadata.count == metadataLength && raw.count == eventLength,"truncated relay frame at byte \(offset)")
            let (value,version)=try RelayMetadata.decoded(metadata)
            let end=offset+UInt64(8+metadataLength+eventLength)
            try require(endOffset == nil || end <= endOffset!,"relay frame crosses requested boundary")
            try emit(Record(relayOffset:offset,relayEnd:end,metadataVersion:version,kind:value.kind,file:value.file,
                            observedPosition:value.observedPosition,eventBytes:eventLength,rawBase64:includeRaw ? raw.base64EncodedString() : nil))
            offset=end
        }
    }
}
