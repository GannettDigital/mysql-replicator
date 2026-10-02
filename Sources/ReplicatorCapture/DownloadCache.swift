import Foundation
import ReplicatorCodec

public struct DownloadSnapshot: Encodable {
    public var frames: UInt64 = 0
    public var eventBytes: UInt64 = 0
    public var batches: UInt64 = 0
    public var queuedBytes = 0
    public var maximumQueuedBytes = 0
    public var maximumQueuedBatches = 0
    public var receiverSeconds: Double = 0
    public var reachedEOF = false
    public let durable = false
}

/// Single receiver, single decoder. Each published file is a complete batch of
/// length-prefixed wire events, including rotation/FDE transport context. This
/// is a disposable cache, NOT an applied checkpoint or MySQL binlog file. No
/// fsync is needed: a new run re-fetches from the caller's authoritative boundary.
final class DownloadCache: @unchecked Sendable {
    private struct Segment { let file: URL; let bytes: Int; let frames: Int }
    private let condition = NSCondition()
    let directory: URL
    let maximumBytes: Int
    let maximumEventBytes: Int
    private let maximumBatches: Int
    private var segments: [Segment] = []
    private var completion: Result<Void,Error>?
    private var counters = DownloadSnapshot()
    private var nextID: UInt64 = 0 // Receiver-only; not shared snapshot storage.

    init(maximumBytes: Int, maximumEventBytes: Int, maximumBatches: Int = 1024) throws {
        guard maximumBytes >= maximumEventBytes+4, maximumEventBytes >= 19, maximumBatches > 0 else {
            throw CaptureError("invalid download cache limits")
        }
        self.maximumBytes=maximumBytes; self.maximumEventBytes=maximumEventBytes; self.maximumBatches=maximumBatches
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("mysql-replicator-download-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    deinit { try? FileManager.default.removeItem(at:directory) }
    var snapshot: DownloadSnapshot {
        condition.lock(); defer { condition.unlock() }; return counters
    }
    func finish(_ result: Result<Void,Error>, elapsed: Double? = nil) {
        condition.lock(); defer { condition.unlock() }
        if completion == nil { completion=result }
        if let elapsed { counters.receiverSeconds=elapsed; if case .success = result { counters.reachedEOF=true } }
        condition.broadcast()
    }
    func checkFailure(ignoringCancellation: Bool = false) throws {
        condition.lock(); defer { condition.unlock() }
        if case .failure(let error) = completion {
            if ignoringCancellation && error is CaptureCancelled { return }
            throw error
        }
    }
    func append(_ frames: [Data], cancellation: CaptureCancellation, timings: StageTimings) throws {
        guard !frames.isEmpty, frames.count <= 4096 else { throw CaptureError("invalid download batch") }
        let data = try timings.measure("download.pack") { () throws -> Data in
            var size=0
            for frame in frames {
                guard (19...maximumEventBytes).contains(frame.count), size <= maximumBytes-frame.count-4 else {
                    throw CaptureError("download batch exceeds cache limit")
                }
                size += frame.count+4
            }
            var result=Data(); result.reserveCapacity(size)
            for frame in frames {
                var count=UInt32(frame.count).littleEndian
                withUnsafeBytes(of:&count) { result.append(contentsOf:$0) }
                result.append(frame)
            }
            return result
        }
        try timings.measure("download.backpressure") {
            condition.lock(); defer { condition.unlock() }
            while true {
                if let completion { try completion.get(); throw CaptureError("download cache already finished") }
                if cancellation.isCancelled { throw CaptureCancelled() }
                if counters.queuedBytes <= maximumBytes-data.count && segments.count < maximumBatches { break }
                _ = condition.wait(until:Date().addingTimeInterval(0.05))
            }
        }
        // Only this receiver allocates sequence numbers. Readers cannot observe
        // the file until write/close succeeds and the descriptor is published.
        let file=directory.appendingPathComponent(String(nextID)+".frames")
        nextID += 1
        try timings.measure("download.write") {
            guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else {
                throw CaptureError("cannot create download cache file")
            }
            let handle=try FileHandle(forWritingTo:file)
            defer { try? handle.close() }
            try handle.write(contentsOf:data)
        }
        condition.lock(); defer { condition.unlock() }
        if let completion { try completion.get(); throw CaptureError("download cache already finished") }
        segments.append(Segment(file:file,bytes:data.count,frames:frames.count))
        counters.batches += 1; counters.frames += UInt64(frames.count)
        counters.eventBytes += UInt64(data.count-frames.count*4)
        counters.queuedBytes += data.count
        counters.maximumQueuedBytes=max(counters.maximumQueuedBytes,counters.queuedBytes)
        counters.maximumQueuedBatches=max(counters.maximumQueuedBatches,segments.count)
        condition.signal()
    }
    func next(cancellation: CaptureCancellation, timings: StageTimings, onIdle: () throws -> Void = {}) throws -> [Data]? {
        let segment: Segment? = try timings.measure("download.cache_wait") {
            condition.lock(); defer { condition.unlock() }
            while true {
                if case .failure(let error) = completion { throw error }
                if cancellation.isCancelled { throw CaptureCancelled() }
                if let first=segments.first { return first }
                if let completion { try completion.get(); return nil }
                condition.unlock()
                do { try onIdle() } catch { condition.lock(); throw error }
                condition.lock()
                if !segments.isEmpty || completion != nil { continue }
                _ = condition.wait(until:Date().addingTimeInterval(0.05))
            }
        }
        guard let segment else { return nil }
        let data = try timings.measure("download.read") {
            let handle=try FileHandle(forReadingFrom:segment.file)
            defer { try? handle.close() }
            let bytes=try handle.read(upToCount:segment.bytes+1) ?? Data()
            guard bytes.count == segment.bytes else { throw CaptureError("download cache truncated or changed; re-fetch from checkpoint") }
            return bytes
        }
        let frames = try timings.measure("download.unpack") { () throws -> [Data] in
            var offset=0, frames:[Data]=[]; frames.reserveCapacity(segment.frames)
            while offset < data.count {
                guard data.count-offset >= 4 else { throw CaptureError("truncated download cache frame header") }
                let size=(0..<4).reduce(0) { $0 | Int(data[offset+$1]) << (8*$1) }; offset += 4
                guard (19...maximumEventBytes).contains(size), size <= data.count-offset else { throw CaptureError("invalid download cache frame size") }
                frames.append(data.subdata(in:offset..<offset+size)); offset += size
            }
            guard frames.count == segment.frames else { throw CaptureError("download cache frame count changed") }
            return frames
        }
        try timings.measure("download.unlink") { try FileManager.default.removeItem(at:segment.file) }
        condition.lock(); segments.removeFirst(); counters.queuedBytes -= segment.bytes
        condition.signal(); condition.unlock()
        return frames
    }
}
