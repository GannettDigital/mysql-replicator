import Foundation
import ReplicatorCodec

public final class ArchiveReplay {
    public let manifest: ArchiveManifest
    private let directory: URL
    private let maximumEventBytes: UInt32
    public init(configuration: ArchiveConfiguration, source: CaptureConfiguration, contract: SourceContract,
                filtered: Bool = false) throws {
        try configuration.validate()
        _ = try source.validate(connection:false)
        directory=URL(fileURLWithPath:configuration.directory).standardizedFileURL
        maximumEventBytes=source.maximumEventBytes ?? 4*1024*1024
        let metadata=directory.appendingPathComponent("manifest.json")
        guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent("incomplete.json").path) else { throw CaptureError("fetch archive is incomplete") }
        if FileManager.default.fileExists(atPath:metadata.path) {
            manifest=try ArchiveIO.read(ArchiveManifest.self,from:metadata)
        } else {
            var names=try configuration.files ?? FileManager.default.contentsOfDirectory(atPath:directory.path).sorted()
            if let first=configuration.firstFile {
                guard let i=names.firstIndex(of:first) else { throw CaptureError("archive firstFile is missing") }
                names=Array(names[i...])
            }
            guard !names.isEmpty,names.count <= 10000 else { throw CaptureError("empty or oversized external archive inventory") }
            var entries:[ArchiveManifest.File]=[],size:UInt64=0,version:String?
            for name in names {
                try ArchiveIO.filename(name)
                let file=directory.appendingPathComponent(name), bytes=try ArchiveIO.regularFile(file)
                guard bytes <= configuration.byteLimit-size else { throw CaptureError("external archive exceeds byte limit") };size += bytes
                if version == nil {
                    let h=try FileHandle(forReadingFrom:file);defer { try? h.close() }
                    guard try h.read(upToCount:4) == Data([0xfe,0x62,0x69,0x6e]),let header=try h.read(upToCount:19),header.count == 19,header[4] == 15 else { throw CaptureError("external archive must contain raw MySQL binlogs") }
                    let n=ArchiveIO.read(header,at:9,as:UInt32.self)
                    guard (23...maximumEventBytes).contains(n),let body=try h.read(upToCount:Int(n)-19),body.count == Int(n)-19 else { throw CaptureError("invalid external format event") }
                    version=try BinlogDecoder(maximumEventBytes:maximumEventBytes).decode(header+body,at:4).detailText
                }
                entries.append(.init(name:name,bytes:bytes,sha256:try ArchiveIO.hash(file)))
            }
            // Raw files identify their format version, not server UUID/settings.
            // These settings describe the operator-selected qualified contract.
            manifest=ArchiveManifest(version:1,sourceUUID:source.sourceUUID,sourceVersion:version ?? "",
                settings:["gtid_mode":"ON","enforce_gtid_consistency":"ON","binlog_format":"ROW","binlog_row_image":"FULL","binlog_checksum":"CRC32","lower_case_table_names":configuration.lowerCaseTableNames.map(String.init) ?? "unknown"],
                files:entries,capturedAt:"unknown",provenance:"external raw files; identity and source contract supplied by operator")
        }
        guard manifest.version == 1, manifest.sourceUUID.lowercased() == source.sourceUUID.lowercased(),
              manifest.sourceVersion.hasPrefix(contract.rawValue),
              manifest.settings["gtid_mode"] == "ON", manifest.settings["binlog_format"] == "ROW",
              manifest.settings["binlog_row_image"] == "FULL", manifest.settings["binlog_checksum"] == "CRC32",
              manifest.settings["enforce_gtid_consistency"] == "ON",
              !filtered || manifest.settings["lower_case_table_names"] == "0",
              !manifest.files.isEmpty, manifest.files.count <= 10000 else { throw CaptureError("archive identity/settings differ from replication profile") }
        var size:UInt64=0, names=Set<String>()
        for file in manifest.files {
            try ArchiveIO.filename(file.name)
            guard names.insert(file.name).inserted, file.bytes <= configuration.byteLimit-size else { throw CaptureError("duplicate archive file or archive byte limit exceeded") }
            size += file.bytes
            let path=directory.appendingPathComponent(file.name)
            guard try ArchiveIO.regularFile(path) == file.bytes, try ArchiveIO.hash(path) == file.sha256 else { throw CaptureError("archive file changed: \(file.name)") }
        }
    }

    /// Validate the complete archive before issuing target writes. Control-only
    /// decoding deliberately does not interpret historical row values.
    public func validate(baseline: String, stopAfterGTIDs: String? = nil) throws {
        let excluded=try GTIDSet(baseline)
        var available=excluded
        for file in manifest.files {
            let path=directory.appendingPathComponent(file.name)
            guard try ArchiveIO.regularFile(path) == file.bytes,try ArchiveIO.hash(path) == file.sha256 else { throw CaptureError("archive changed before replay: \(file.name)") }
        }
        try walk { _,_,_,gtid,complete in
            if complete,let gtid { try available.include(sid:gtid.sid,sequence:gtid.sequence) }
        } previous: { previous,first in
            if first && !excluded.covers(previous) { throw CaptureError("archive starts after required history; baseline does not cover first Previous_gtids") }
        }
        if let stopAfterGTIDs,try !available.covers(GTIDSet(stopAfterGTIDs)) { throw CaptureError("archive does not contain requested stopAfterGTIDs after baseline") }
    }

    private func walk(_ emit:(Data,UInt64,String,SourceGTID?,Bool) throws -> Void,
                      previous: (GTIDSet,Bool) throws -> Void = {_,_ in}) throws {
        var covered:GTIDSet?, rotated:BinlogCoordinate?, previousName:String?
        for entry in manifest.files {
            let decoder=try BinlogDecoder(maximumEventBytes:maximumEventBytes)
            var decoderOffset:UInt64=4, pending:SourceGTID?, begun=false, hasPrevious=false, ended=false
            if let rotated { guard rotated.file == entry.name && rotated.position == 4 else { throw CaptureError("archive rotation destination differs from manifest") } }
            else if let previousName {
                func numbered(_ name:String) -> (String,UInt64)? {
                    guard let dot=name.lastIndex(of:"."), let n=UInt64(name[name.index(after:dot)...]) else { return nil }
                    return (String(name[..<dot]),n)
                }
                guard let a=numbered(previousName),let b=numbered(entry.name),a.0 == b.0,a.1 < UInt64.max,b.1 == a.1+1 else { throw CaptureError("missing or unordered archive files") }
            }
            rotated=nil
            try ArchiveFileReader(file:directory.appendingPathComponent(entry.name),maximumEventBytes:maximumEventBytes).scan { frame,offset in
                guard !ended else { throw CaptureError("archive event after rotation or STOP") }
                var control:BinlogControl?
                if [2,3,4,15,16,33,34,35].contains(frame[4]) {
                    let event=try decoder.decode(frame,at:decoderOffset)
                    decoderOffset += UInt64(frame.count); control=event.control
                    if frame[4] == 15 {
                        guard event.detailText?.hasPrefix(manifest.sourceVersion.components(separatedBy:".").prefix(2).joined(separator:".")) == true else { throw CaptureError("archive format version differs from manifest") }
                    }
                }
                let identity:SourceGTID?
                var complete=false
                switch control {
                case .previousGTIDs:
                    guard !hasPrevious, pending == nil, offset > 4 else { throw CaptureError("unexpected archive Previous_gtids") }
                    let prior=try ArchiveIO.previousGTIDs(frame)
                    if let covered { guard covered == prior else { throw CaptureError("archive GTID history gap between files") } }
                    try previous(prior,covered == nil); covered=prior; hasPrevious=true
                case .gtid(let gtid):
                    guard hasPrevious, pending == nil, let covered, !covered.contains(sid:gtid.sid,sequence:gtid.sequence) else { throw CaptureError("missing preamble, duplicate GTID, or incomplete archive transaction") }
                    pending=gtid; begun=false
                case .anonymousGTID: throw CaptureError("anonymous transaction in GTID archive")
                case .query(let query):
                    guard pending != nil,query.errorCode == 0 else { throw CaptureError("query without GTID or source query error in archive") }
                    let sql=String(decoding:query.sql,as:UTF8.self)
                    if sql == "BEGIN" { guard !begun else { throw CaptureError("nested archive BEGIN") }; begun=true }
                    else if sql == "COMMIT" || sql == "ROLLBACK" { guard begun else { throw CaptureError("archive transaction end without BEGIN") }; complete=true }
                    else if !begun { complete=true }
                    else { throw CaptureError("non-control query inside archive row transaction") }
                case .xid:
                    guard pending != nil,begun else { throw CaptureError("archive XID without transaction") }; complete=true
                case .rotate(let destination):
                    guard pending == nil else { throw CaptureError("archive rotation inside transaction") }; rotated=destination; ended=true
                case .stop:
                    guard pending == nil else { throw CaptureError("archive STOP inside transaction") }; ended=true
                case .formatDescription: break
                case nil:
                    guard hasPrevious,pending != nil,begun else { throw CaptureError("archive payload outside transaction") }
                }
                identity=pending
                try emit(frame,offset,entry.name,identity,complete)
                if complete, let pending {
                    try covered!.include(sid:pending.sid,sequence:pending.sequence)
                    begun=false
                }
                if complete { pending=nil }
            }
            guard hasPrevious,pending == nil else { throw CaptureError("incomplete archive preamble or transaction at EOF: \(entry.name)") }
            previousName=entry.name
        }
    }

    public func run(configuration: CaptureConfiguration, cancellation: CaptureCancellation, retainRawBytes: Bool = false,
                    emitEvent: @escaping (LiveRecord) throws -> Void,
                    emitTransaction: @escaping (CompleteTransaction) throws -> Void,
                    resolveSchema: ((DecodedEvent,BinlogCoordinate) throws -> [ColumnInterpretation])?,
                    timings: StageTimings, ignoreTable: ((String,String) -> Bool)?) throws {
        let excluded=try GTIDSet(configuration.start.executedGTIDs)
        try validate(baseline:excluded.canonical,stopAfterGTIDs:configuration.stopAfterGTIDs)
        let processor=try StreamProcessor(config:configuration,includeRaw:!retainRawBytes,retainRawBytes:retainRawBytes,emitEvent:emitEvent,
            emitTransaction:emitTransaction,resolveSchema:resolveSchema,timings:timings,allowDDL:true,ignoreTable:ignoreTable)
        struct Limit: Error {}
        if processor.stopReason != nil { return }
        do {
            try walk { frame,offset,file,gtid,complete in
                if cancellation.isCancelled { throw CaptureCancelled() }
                if processor.stopReason != nil { throw Limit() }
                if offset == 4 { try processor.consume(ArchiveIO.announce(file)) }
                if let gtid, excluded.contains(sid:gtid.sid,sequence:gtid.sequence) {
                    if complete { try processor.skipArchivedGroup(to:BinlogCoordinate(file:file,position:offset+UInt64(frame.count))) }
                } else {
                    try timings.measure("archive.decode") { try processor.consume(frame) }
                }
            }
        } catch is Limit { }
        try processor.finish()
        if processor.stopReason == nil && (configuration.stopAfterTransactions != nil || configuration.stopAfterGTIDs != nil) { throw CaptureError("archive EOF before requested stop condition") }
    }
}
