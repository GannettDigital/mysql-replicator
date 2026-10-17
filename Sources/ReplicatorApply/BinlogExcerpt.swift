import Foundation
import ReplicatorCapture

/// Raw ranges preserve original offsets even when corruption prevents decoding.
/// The prefix contains the format event when it fits. Relay frames retain the
/// decoded transaction and its table maps; an excerpt is never a replay archive.
enum BinlogExcerpt {
    struct Result { let files:[URL];let complete:Bool }
    struct Index:Codable {
        let sourceFile:String
        let sourceBytes:UInt64
        let focusStart:UInt64
        let focusEnd:UInt64
        let focusComplete:Bool
        let standaloneReplayFile:Bool
        let ranges:[Segment]
        let omitted:[Segment]
    }
    struct Segment:Codable { let start:UInt64;let end:UInt64;let file:String? }
    static func collect(_ source:URL,to directory:URL,prefix:String,focus:Range<UInt64>,maximumBytes:UInt64) throws -> Result {
        let size=try ArchiveIO.regularFile(source)
        try require(maximumBytes >= 4096,"binlog excerpt budget too small")
        let head=min(size,min(64*1024,maximumBytes/4))
        let start=min(focus.lowerBound,size),end=min(focus.upperBound,size)
        let remaining=maximumBytes-head
        let span=min(end-start,remaining)
        let before=(remaining-span)/2
        let low=start > before ? start-before : 0
        let high=low+min(size-low,remaining)
        var bounds:[Range<UInt64>]=[0..<head]
        if low <= head { bounds=[0..<max(head,high)] }
        else if high > low { bounds.append(low..<high) }
        var files:[URL]=[],segments:[Segment]=[],omitted:[Segment]=[]
        let input=try FileHandle(forReadingFrom:source);defer { try? input.close() }
        var last:UInt64=0
        for (index,range) in bounds.enumerated() {
            if range.lowerBound > last { omitted.append(.init(start:last,end:range.lowerBound,file:nil)) }
            let file=directory.appendingPathComponent("\(prefix)-\(index).bytes")
            guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw ApplyError("cannot create binlog excerpt") }
            let output=try FileHandle(forWritingTo:file);defer { try? output.close() }
            try input.seek(toOffset:range.lowerBound)
            var left=range.count
            while left > 0 {
                let bytes=try input.read(upToCount:min(left,1024*1024)) ?? Data()
                try require(!bytes.isEmpty,"archive input truncated during excerpt collection")
                try output.write(contentsOf:bytes);left -= bytes.count
            }
            files.append(file);segments.append(.init(start:range.lowerBound,end:range.upperBound,file:file.lastPathComponent));last=range.upperBound
        }
        if last < size { omitted.append(.init(start:last,end:size,file:nil)) }
        let index=Index(sourceFile:source.lastPathComponent,sourceBytes:size,focusStart:focus.lowerBound,focusEnd:focus.upperBound,
            focusComplete:focus.upperBound <= size && bounds.contains { $0.lowerBound <= focus.lowerBound && $0.upperBound >= focus.upperBound },
            standaloneReplayFile:false,ranges:segments,omitted:omitted)
        let file=directory.appendingPathComponent(prefix+".json")
        try ArchiveIO.write(index,to:file);files.append(file)
        return Result(files:files,complete:omitted.isEmpty)
    }
}
