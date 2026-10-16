import Foundation
import ReplicatorCodec

public final class ArchiveReplay {
    /// File inventory and source contract for fetched or external archives.
    public let manifest: ArchiveManifest
    public struct Progress: Encodable {
        public let kind = "archive_progress"
        public let phase: String
        public let file: String
        public let filesCompleted: Int
        public let filesTotal: Int
        public let bytesRead: UInt64
        public let bytesTotal: UInt64
        public let elapsedSeconds: Double
    }
    private let progress: (Progress) -> Void
    private var validation: (identities:[ArchiveFileIdentity], previous:GTIDSet, available:GTIDSet)?
    private let directory: URL
    private let maximumEventBytes: UInt32
    public init(configuration: ArchiveConfiguration, source: CaptureConfiguration, contract: SourceContract,
                filtered _: Bool = false, progress: @escaping (Progress) -> Void = { _ in }) throws {
        self.progress=progress
        try configuration.validate()
        _ = try source.validate(connection:false)
        directory=URL(fileURLWithPath:configuration.directory).standardizedFileURL
        maximumEventBytes=source.eventByteLimit
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
                entries.append(.init(name:name,bytes:bytes))
            }
            // Raw files identify their format version, not server UUID/settings.
            // These settings describe the operator-selected qualified contract.
            manifest=ArchiveManifest(version:2,sourceUUID:source.sourceUUID,sourceVersion:version ?? "",
                settings:["gtid_mode":"ON","enforce_gtid_consistency":"ON","binlog_format":"ROW","binlog_row_image":"FULL","binlog_checksum":"CRC32","lower_case_table_names":String(configuration.lowerCaseTableNames ?? source.tableNameCaseSetting)],
                files:entries,capturedAt:"unknown",provenance:"external raw files; identity and source contract supplied by operator")
        }
        guard (1...2).contains(manifest.version), manifest.sourceUUID.lowercased() == source.sourceUUID.lowercased(),
              manifest.sourceVersion.hasPrefix(contract.rawValue),
              manifest.settings["gtid_mode"] == "ON", manifest.settings["binlog_format"] == "ROW",
              manifest.settings["binlog_row_image"] == "FULL", manifest.settings["binlog_checksum"] == "CRC32",
              manifest.settings["enforce_gtid_consistency"] == "ON",
              manifest.settings["lower_case_table_names"] == String(source.tableNameCaseSetting),
              !manifest.files.isEmpty, manifest.files.count <= 10000 else { throw CaptureError("archive identity/settings differ from replication profile") }
        var size:UInt64=0, names=Set<String>()
        for file in manifest.files {
            try ArchiveIO.filename(file.name)
            guard names.insert(file.name).inserted, file.bytes <= configuration.byteLimit-size else { throw CaptureError("duplicate archive file or archive byte limit exceeded") }
            size += file.bytes
            let path=directory.appendingPathComponent(file.name)
            guard try ArchiveIO.regularFile(path) == file.bytes else { throw CaptureError("archive file changed: \(file.name)") }
        }
    }

    /// Validate the complete archive before issuing target writes. Control-only
    /// decoding deliberately does not interpret historical row values.
    public func validate(baseline: String, stopAfterGTIDs: String? = nil,
                         isCancelled: () -> Bool = { false }) throws {
        let excluded=try GTIDSet(baseline)
        let started=DispatchTime.now().uptimeNanoseconds
        let total=manifest.files.reduce(UInt64(0)) { $0+$1.bytes }
        func report(_ phase:String,_ file:String,_ completed:Int,_ bytes:UInt64) {
            progress(Progress(phase:phase,file:file,filesCompleted:completed,filesTotal:manifest.files.count,
                bytesRead:bytes,bytesTotal:total,elapsedSeconds:Double(DispatchTime.now().uptimeNanoseconds-started)/1e9))
        }
        func checkBaseline(_ previous:GTIDSet) throws {
            guard excluded.covers(previous) else {
                throw CaptureError("archive starts after required history; baseline does not cover first Previous_gtids; file=\(manifest.files[0].name); requiredGTIDs=\(previous.canonical); appliedGTIDs=\(excluded.canonical)")
            }
        }
        func checkStop(_ available:GTIDSet) throws {
            let combined=try available.union(excluded)
            if let stopAfterGTIDs,try !combined.covers(GTIDSet(stopAfterGTIDs)) {
                throw CaptureError("archive does not contain requested stopAfterGTIDs after baseline")
            }
        }
        if isCancelled() { throw CaptureCancelled() }
        if let validation {
            try checkIdentities(validation.identities)
            try checkBaseline(validation.previous)
            try checkStop(validation.available)
            report("validation_reused",manifest.files[0].name,manifest.files.count,0)
            return
        }
        let identities=try manifest.files.map { try ArchiveFileIdentity(directory.appendingPathComponent($0.name)) }
        report("preamble",manifest.files[0].name,0,0)
        let first=try ArchivePreamble.read(file:directory.appendingPathComponent(manifest.files[0].name),maximumEventBytes:maximumEventBytes)
        let previous=try GTIDSet(first.previousGTIDs)
        try checkBaseline(previous)
        try checkIdentities(identities)
        var available=previous,read:UInt64=0,completed=0,lastReport=started,nextReportByte:UInt64=0
        report("validation",manifest.files[0].name,0,0)
        try walk(identities:identities) { frame,offset,file,gtid,complete in
            if isCancelled() { throw CaptureCancelled() }
            if offset == 4 { read += 4 }
            read += UInt64(frame.count)
            if complete,let gtid { try available.include(gtid) }
            if read >= nextReportByte {
                nextReportByte=read+1024*1024
                let now=DispatchTime.now().uptimeNanoseconds
                if now-lastReport >= 1_000_000_000 {
                    report("validation",file,completed,read);lastReport=now
                }
            }
        } previous: { prior,first in
            if first { try checkBaseline(prior) }
        } finished: { file in
            completed += 1;report("validation",file,completed,read)
        }
        try checkIdentities(identities)
        try checkStop(available)
        validation=(identities,previous,available)
        report("validated",manifest.files.last!.name,completed,read)
    }

    private func checkIdentities(_ identities:[ArchiveFileIdentity]) throws {
        for (entry,identity) in zip(manifest.files,identities) { try checkIdentity(entry,identity) }
    }
    private func checkIdentity(_ entry:ArchiveManifest.File,_ identity:ArchiveFileIdentity) throws {
        guard identity.size == entry.bytes,try ArchiveFileIdentity(directory.appendingPathComponent(entry.name)) == identity else {
            throw CaptureError("archive changed before or during replay: \(entry.name)")
        }
    }

    private func walk(identities:[ArchiveFileIdentity]? = nil,
                      _ emit:(Data,UInt64,String,SourceGTID?,Bool) throws -> Void,
                      previous: (GTIDSet,Bool) throws -> Void = {_,_ in},
                      finished: (String) -> Void = {_ in}) throws {
        var covered:GTIDSet?, rotated:BinlogCoordinate?, previousName:String?
        for (index,entry) in manifest.files.enumerated() {
            if let identities { try checkIdentity(entry,identities[index]) }
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
                if [2,3,4,15,16,33,34,35,42].contains(frame[4]) {
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
                    guard hasPrevious, pending == nil, let covered, !covered.contains(gtid) else { throw CaptureError("missing preamble, duplicate GTID, or incomplete archive transaction") }
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
                    try covered!.include(pending)
                    begun=false
                }
                if complete { pending=nil }
            }
            guard hasPrevious,pending == nil else { throw CaptureError("incomplete archive preamble or transaction at EOF: \(entry.name)") }
            if let identities { try checkIdentity(entry,identities[index]) }
            previousName=entry.name
            finished(entry.name)
        }
    }

    public func run(configuration: CaptureConfiguration, cancellation: CaptureCancellation, retainRawBytes: Bool = false,
                    emitEvent: @escaping (LiveRecord) throws -> Void,
                    emitTransaction: @escaping (CompleteTransaction) throws -> Void,
                    resolveSchema: ((DecodedEvent,BinlogCoordinate) throws -> [ColumnInterpretation])?,
                    timings: StageTimings, ignoreTable: ((String,String) -> Bool)?) throws {
        let excluded=try GTIDSet(configuration.start.executedGTIDs)
        try validate(baseline:excluded.canonical,stopAfterGTIDs:configuration.stopAfterGTIDs,isCancelled:{ cancellation.isCancelled })
        let processor=try StreamProcessor(config:configuration,includeRaw:!retainRawBytes,retainRawBytes:retainRawBytes,emitEvent:emitEvent,
            emitTransaction:emitTransaction,resolveSchema:resolveSchema,timings:timings,allowDDL:true,ignoreTable:ignoreTable)
        struct Limit: Error {}
        if processor.stopReason != nil { return }
        do {
            try walk(identities:validation!.identities) { frame,offset,file,gtid,complete in
                if cancellation.isCancelled { throw CaptureCancelled() }
                if processor.stopReason != nil { throw Limit() }
                if offset == 4 { try processor.consume(ArchiveIO.announce(file)) }
                if let gtid, excluded.contains(gtid) {
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
