import Foundation
import Crypto
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public struct ArchiveConfiguration: Decodable {
    public let directory: String
    public let firstFile: String?
    public let files: [String]?
    public let lowerCaseTableNames: Int?
    public let maximumBytes: UInt64?
    public var byteLimit: UInt64 { maximumBytes ?? 64*1024*1024*1024 }
    public func validate() throws {
        guard !directory.isEmpty, byteLimit >= 4 else { throw CaptureError("invalid archive directory or maximumBytes") }
        if let firstFile { try ArchiveIO.filename(firstFile) }
        if let files {
            guard !files.isEmpty,files.count <= 10000,Set(files).count == files.count else { throw CaptureError("invalid archive files list") }
            for file in files { try ArchiveIO.filename(file) }
        }
    }
}

public struct ArchiveManifest: Codable {
    public struct File: Codable {
        public let name: String
        public let bytes: UInt64
        public let sha256: String
    }
    public let version: Int
    public let sourceUUID: String
    public let sourceVersion: String
    public let settings: [String:String]
    public let files: [File]
    public let capturedAt: String
    public var provenance: String? = nil
}

/// Bounded I/O for immutable archives and diagnostic evidence. No shell commands.
public enum ArchiveIO {
    static func syncDirectory(_ directory: URL) throws {
        let fd=open(directory.path,O_RDONLY)
        guard fd >= 0 else { throw CaptureError("cannot open archive directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CaptureError("cannot synchronize archive directory") }
    }
    public static func filename(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255,
              !value.contains("/"), !value.contains("\\"), !value.utf8.contains(0) else { throw CaptureError("invalid archive filename") }
    }
    public static func regularFile(_ file: URL) throws -> UInt64 {
        let a=try FileManager.default.attributesOfItem(atPath:file.path)
        guard a[.type] as? FileAttributeType == .typeRegular, let n=a[.size] as? NSNumber else { throw CaptureError("archive input must be a regular file: \(file.lastPathComponent)") }
        return n.uint64Value
    }
    public static func hash(_ file: URL) throws -> String {
        _ = try regularFile(file)
        let handle=try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        var digest=SHA256()
        while let block=try handle.read(upToCount:1024*1024), !block.isEmpty { digest.update(data:block) }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    public static func write<T: Encodable>(_ value: T,to file: URL) throws {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(value).write(to:file,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    public static func read<T: Decodable>(_ type:T.Type,from file:URL,maximum:Int=16*1024*1024) throws -> T {
        guard try regularFile(file) <= UInt64(maximum) else { throw CaptureError("archive manifest exceeds limit") }
        return try JSONDecoder().decode(type,from:Data(contentsOf:file))
    }
    public static func read<T: FixedWidthInteger>(_ bytes: Data,at: Int,as: T.Type) -> T {
        (0..<MemoryLayout<T>.size).reduce(T(0)) { $0 | T(bytes[at+$1]) << (8*$1) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc=UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    public static func crc32(_ bytes: Data, format: Bool = false) -> UInt32 {
        var crc=UInt32.max
        for (i,b) in bytes.enumerated() {
            let byte = format && i == 17 ? b & ~1 : b
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)]
        }
        return crc ^ UInt32.max
    }
    static func pseudo(type: UInt8,position: UInt32,body: Data) -> Data {
        var frame=Data(repeating:0,count:19); frame[4]=type
        if type == 4 { frame[17]=0x20 }
        var length=UInt32(23+body.count).littleEndian, next=position.littleEndian
        withUnsafeBytes(of:&length) { frame.replaceSubrange(9..<13,with:$0) }
        withUnsafeBytes(of:&next) { frame.replaceSubrange(13..<17,with:$0) }
        frame.append(body)
        var crc=crc32(frame).littleEndian; withUnsafeBytes(of:&crc) { frame.append(contentsOf:$0) }
        return frame
    }
    static func announce(_ file: String) -> Data {
        var four=UInt64(4).littleEndian
        var body=Data(); withUnsafeBytes(of:&four) { body.append(contentsOf:$0) }; body.append(Data(file.utf8))
        return pseudo(type:4,position:0,body:body)
    }
    static func previousGTIDs(_ frame: Data) throws -> GTIDSet {
        var at=19
        func number() throws -> UInt64 {
            guard at+8 <= frame.count-4 else { throw CaptureError("truncated previous-GTID set") }
            defer { at += 8 }; return read(frame,at:at,as:UInt64.self)
        }
        let count=try number(); guard count <= 64 else { throw CaptureError("previous-GTID SID limit exceeded") }
        var entries:[String]=[]
        for _ in 0..<count {
            guard at+16 <= frame.count-4 else { throw CaptureError("truncated previous-GTID SID") }
            let bytes=Array(frame[at..<at+16]); at += 16
            let uuid=UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
            let ranges=try number(); guard (1...4096).contains(ranges) else { throw CaptureError("previous-GTID interval limit exceeded") }
            var entry=uuid.uuidString.lowercased()
            for _ in 0..<ranges {
                let low=try number(), high=try number()
                guard low > 0, high > low else { throw CaptureError("invalid previous-GTID interval") }
                entry += ":\(low)-\(high-1)"
            }
            entries.append(entry)
        }
        guard at == frame.count-4 else { throw CaptureError("trailing previous-GTID bytes") }
        return try GTIDSet(entries.joined(separator:","))
    }
}

/// Physical-file validation is independent of supported row types. Fetch can
/// preserve events which the semantic decoder/applier will subsequently reject.
struct ArchiveFileReader {
    let file: URL
    let maximumEventBytes: UInt32
    func scan(_ emit:(Data,UInt64) throws -> Void) throws {
        _ = try ArchiveIO.regularFile(file)
        let handle=try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        func read(_ count: Int, eof: Bool = false) throws -> Data {
            var data=Data()
            while data.count < count {
                let block=try handle.read(upToCount:count-data.count) ?? Data()
                if block.isEmpty {
                    if eof && data.isEmpty { return data }
                    throw CaptureError("truncated archive: \(file.lastPathComponent)")
                }
                data.append(block)
            }
            return data
        }
        guard try read(4) == Data([0xfe,0x62,0x69,0x6e]) else { throw CaptureError("invalid binlog magic") }
        var offset:UInt64=4
        while true {
            let header=try read(19,eof:true); if header.isEmpty { break }
            let length=ArchiveIO.read(header,at:9,as:UInt32.self)
            guard (23...maximumEventBytes).contains(length) else { throw CaptureError("invalid archive event length at \(file.lastPathComponent):\(offset)") }
            let frame=try header+read(Int(length)-19)
            guard UInt64(ArchiveIO.read(frame,at:13,as:UInt32.self)) == offset+UInt64(length),
                  ArchiveIO.read(frame,at:17,as:UInt16.self) & 0x20 == 0 else { throw CaptureError("nonphysical archive event at \(file.lastPathComponent):\(offset)") }
            guard ArchiveIO.crc32(Data(frame.dropLast(4)),format:frame[4] == 15) == ArchiveIO.read(frame,at:frame.count-4,as:UInt32.self) else { throw CaptureError("archive CRC mismatch at \(file.lastPathComponent):\(offset)") }
            guard (offset == 4) == (frame[4] == 15) else { throw CaptureError("archive requires exactly one initial format event") }
            try emit(frame,offset); offset += UInt64(length)
        }
        guard offset > 4 else { throw CaptureError("empty binlog archive file") }
    }
}
