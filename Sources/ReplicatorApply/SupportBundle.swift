import Foundation
import CSQLite
import ReplicatorCapture
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public struct SupportBundleConfiguration: Decodable {
    public struct Options: Decodable {
        public enum Format: String, Decodable { case tar, directory }
        public var output: String?
        public let onBlocked: Bool?
        public let directory: String?
        public let format: Format?
        public let maximumBytes: UInt64?
        public let logs: [String]?
        public var binlogContextBytes: UInt64? = nil
        func validate(stateDirectory: String) throws {
            try require((maximumBytes ?? 2*1024*1024*1024) >= 1024*1024,"support bundle maximumBytes must be at least 1 MiB")
            try require((binlogContextBytes ?? 4*1024*1024) >= 4096 && (binlogContextBytes ?? 0) <= 256*1024*1024,"support bundle binlogContextBytes must be 4 KiB through 256 MiB")
            if onBlocked == true {
                try require(!(directory ?? "").isEmpty,"supportBundle.onBlocked requires directory")
                try SupportBundle.requireOutsideState(URL(fileURLWithPath:directory!), state:URL(fileURLWithPath:stateDirectory))
            }
        }
    }
    public let stateDirectory: String
    public let supportBundle: Options
    public let archive: ArchiveConfiguration?
    enum CodingKeys: String, CodingKey { case stateDirectory,supportBundle,archive }
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        stateDirectory=try values.decode(String.self,forKey:.stateDirectory)
        supportBundle=try values.decodeIfPresent(Options.self,forKey:.supportBundle)
            ?? Options(output:nil,onBlocked:nil,directory:nil,format:nil,maximumBytes:nil,logs:nil)
        archive=try values.decodeIfPresent(ArchiveConfiguration.self,forKey:.archive)
    }
    init(stateDirectory:String,supportBundle:Options,archive:ArchiveConfiguration?) {
        self.stateDirectory=stateDirectory;self.supportBundle=supportBundle;self.archive=archive
    }
}

public enum SupportBundle {
    public struct Summary: Encodable {
        public let output: String
        public let containsCustomerData = true
        public let files: Int
        public let omitted: [String]
    }
    public struct AutomaticResult: Encodable {
        public let status: String
        public let bundle: Summary?
        public let reason: String?
        public init(status:String,bundle:Summary?,reason:String?) {
            self.status=status;self.bundle=bundle;self.reason=reason
        }
    }
    private struct Entry: Encodable {
        let name: String
        let bytes: UInt64
        let sha256: String
    }
    static func requireOutsideState(_ output: URL, state: URL) throws {
        let path=output.standardizedFileURL.resolvingSymlinksInPath().path
        let root=state.standardizedFileURL.resolvingSymlinksInPath().path
        try require(path != root && !path.hasPrefix(root+"/"),"support bundle output must be outside the state directory")
    }

    /// Call only after ApplyRun has unwound and released its writer and workers.
    /// Collection failures are diagnostic; they must not replace the apply error.
    public static func onBlocked(_ failure: ApplyRunError, configuration c: SupportBundleConfiguration,
                                 redactedConfiguration: Data, version: String) -> AutomaticResult? {
        guard failure.progress.lifecycle == "BLOCKED", c.supportBundle.onBlocked == true else { return nil }
        do {
            try c.supportBundle.validate(stateDirectory:c.stateDirectory)
            let directory=URL(fileURLWithPath:c.supportBundle.directory!).standardizedFileURL
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let stamp=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"")
            let suffix=c.supportBundle.format == .directory ? "" : ".tar"
            var options=c.supportBundle
            options.output=directory.appendingPathComponent("blocked-"+stamp+"-"+UUID().uuidString+suffix).path
            struct Failure: Encodable { let error = "apply_failed"; let reason:String; let code:ApplyErrorCode?; let progress:ApplySummary }
            let diagnostic=try JSONEncoder().encode(Failure(reason:failure.reason,code:failure.code,progress:failure.progress))
            let request=SupportBundleConfiguration(stateDirectory:c.stateDirectory,supportBundle:options,archive:c.archive)
            let bundle=try run(configuration:request,redactedConfiguration:redactedConfiguration,version:version,failureDiagnostic:diagnostic)
            return AutomaticResult(status:"collected",bundle:bundle,reason:nil)
        } catch { return AutomaticResult(status:"failed",bundle:nil,reason:String(describing:error)) }
    }

    public static func run(configuration c:SupportBundleConfiguration,redactedConfiguration:Data,version:String,
                           failureDiagnostic:Data? = nil) throws -> Summary {
        let fm=FileManager.default, state=URL(fileURLWithPath:c.stateDirectory).standardizedFileURL
        try c.supportBundle.validate(stateDirectory:c.stateDirectory)
        let output:URL
        if let destination=c.supportBundle.output {
            try require(!destination.isEmpty,"support bundle output must not be empty")
            output=URL(fileURLWithPath:destination).standardizedFileURL
        } else {
            let directory=c.supportBundle.directory.map { URL(fileURLWithPath:$0) }
                ?? state.deletingLastPathComponent().appendingPathComponent("support-bundles")
            let suffix=c.supportBundle.format == .directory ? "" : ".tar"
            output=directory.appendingPathComponent("support-"+UUID().uuidString+suffix).standardizedFileURL
        }
        let limit=c.supportBundle.maximumBytes ?? 2*1024*1024*1024
        try require(!c.stateDirectory.isEmpty, "support bundle requires stateDirectory")
        try require(limit >= 1024*1024,"support bundle maximumBytes must be at least 1 MiB")
        try require(!fm.fileExists(atPath:output.path),"support bundle output already exists")
        try requireOutsideState(output,state:state)
        let fd=open(state.appendingPathComponent("writer.lock").path,O_RDONLY|O_NOFOLLOW)
        try require(fd >= 0,"existing state writer lock is required")
        let lock=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer { try? lock.close() }
        try require(flock(fd,LOCK_EX|LOCK_NB) == 0,"stop the applier before collecting a support bundle; state has an active writer")
        try fm.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let working=output.deletingLastPathComponent().appendingPathComponent(".support-"+UUID().uuidString)
        try fm.createDirectory(at:working,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? fm.removeItem(at:working) }
        let snapshot=working.appendingPathComponent("state.sqlite")
        let original=state.appendingPathComponent("state.sqlite")
        _ = try ArchiveIO.regularFile(original)
        var db:OpaquePointer?, copy:OpaquePointer?
        defer { sqlite3_close(copy);sqlite3_close(db) }
        try require(sqlite3_open_v2(original.path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK,"cannot open state for support snapshot")
        let statements=SQLiteStatementCache(db:db!,timings:.init(),profiling:false);defer { statements.close() }
        let pageCount=try statements.query("PRAGMA page_count"),pageSize=try statements.query("PRAGMA page_size")
        guard let count=UInt64(pageCount[0][0] ?? ""),let size=UInt64(pageSize[0][0] ?? ""),size > 0,count <= (limit-65536)/size else { throw ApplyError("SQLite snapshot exceeds support bundle limit") }
        guard fm.createFile(atPath:snapshot.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw ApplyError("cannot create support snapshot") }
        try require(sqlite3_open_v2(snapshot.path,&copy,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK,"cannot create SQLite support backup")
        guard let backup=sqlite3_backup_init(copy,"main",db,"main") else { throw ApplyError("cannot initialize SQLite support backup") }
        let result=sqlite3_backup_step(backup,-1),finished=sqlite3_backup_finish(backup)
        try require(result == SQLITE_DONE && finished == SQLITE_OK,"SQLite support backup failed")
        sqlite3_close(copy);copy=nil
        // Backup copies a WAL-mode header too. Reopen the copy and switch only
        // the copy to DELETE mode so the extracted DB needs no WAL/SHM sidecars.
        try require(sqlite3_open_v2(snapshot.path,&copy,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK,"cannot finalize SQLite support backup")
        try require(sqlite3_exec(copy,"PRAGMA journal_mode=DELETE",nil,nil,nil) == SQLITE_OK,"cannot make standalone SQLite support backup")
        sqlite3_close(copy);copy=nil
        let q=try statements.query("SELECT lifecycle,durable_relay_length,applied_file,active_gtid,applied_position FROM state WHERE id=1")
        try require(q.count == 1,"missing support state row")
        if failureDiagnostic != nil { try require(q[0][0] == "BLOCKED","automatic bundle requires durable BLOCKED state") }
        let durable=UInt64(q[0][1] ?? "")
        let configFile=working.appendingPathComponent("configuration.json")
        try redactedConfiguration.write(to:configFile,options:.withoutOverwriting)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:configFile.path)
        let info=working.appendingPathComponent("diagnostics.json")
        try ArchiveIO.write(["version":version,"containsCustomerData":"true","lifecycle":q[0][0] ?? "unknown","durableRelayBytes":q[0][1] ?? "unknown","pendingGTID":q[0][3] ?? "","collection":"writer lock held; SQLite online backup; original state unchanged"],to:info)
        var paths:[(String,URL)]=[],entries:[Entry]=[],omitted:[String]=[],total:UInt64=1024
        func include(_ path:URL,as name:String,required:Bool=false) throws {
            do {
                try require(name.utf8.count <= 100,"support entry name exceeds ustar limit")
                let bytes=try ArchiveIO.regularFile(path)
                try require(bytes < 8*1024*1024*1024,"support entry exceeds ustar size limit")
                let overhead:UInt64=512+((512-bytes%512)%512)
                guard total <= limit-65536,bytes <= limit-65536-total,overhead <= limit-65536-total-bytes else {
                    if required { throw ApplyError("required support evidence exceeds size limit") }
                    omitted.append(name+": size limit; original file retained locally");return
                }
                let hash=try ArchiveIO.hash(path)
                entries.append(.init(name:name,bytes:bytes,sha256:hash));paths.append((name,path));total += bytes+overhead
            } catch {
                if required { throw error }
                omitted.append(name+": unavailable (\(error))")
            }
        }
        try include(snapshot,as:"state.sqlite",required:true)
        try include(configFile,as:"configuration.json",required:true)
        try include(info,as:"diagnostics.json",required:true)
        if let failureDiagnostic {
            let failure=working.appendingPathComponent("failure.json")
            try failureDiagnostic.write(to:failure,options:.withoutOverwriting)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:failure.path)
            try include(failure,as:"failure.json",required:true)
        }
        // Save small archive diagnostics before optional payload files use the budget.
        var archiveInputs:[(String,URL)]=[]
        var archiveRanges:[String:[Range<UInt64>]]=[:]
        if let archive=c.archive {
            let root=URL(fileURLWithPath:archive.directory)
            let manifest=root.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath:manifest.path) { try include(manifest,as:"archive/manifest.json") }
            var names:[String]=[]
            if let m=try? ArchiveIO.read(ArchiveManifest.self,from:manifest) { names=m.files.map(\.name) }
            else {
                names=archive.files ?? (try? fm.contentsOfDirectory(atPath:root.path).sorted()) ?? []
                if let first=archive.firstFile,let i=names.firstIndex(of:first) { names=Array(names[i...]) }
            }
            let groups=try statements.query("SELECT source_file,start_position,end_position FROM groups WHERE status='PENDING' ORDER BY sequence LIMIT 16")
            let pending=groups.compactMap{$0[0]}
            for row in groups {
                if let name=row[0],let start=UInt64(row[1] ?? ""),let end=UInt64(row[2] ?? ""),end >= start {
                    archiveRanges[name,default:[]].append(start..<end)
                }
            }
            if let name=q[0][2],let offset=UInt64(q[0][4] ?? ""),archiveRanges[name] == nil {
                archiveRanges[name]=[offset..<offset]
            }
            let selected=Set(names)
            let preferred=(pending+(q[0][2].map{[$0]} ?? [])).filter { selected.contains($0) }+names.reversed()
            var seen=Set<String>()
            for name in preferred where name != "manifest.json" && seen.insert(name).inserted {
                do { try ArchiveIO.filename(name);archiveInputs.append((name,root.appendingPathComponent(name))) }
                catch { omitted.append("archive input rejected: \(name)") }
            }
            struct FileDiagnostic:Encodable {
                let name:String
                var bytes:UInt64?
                var preamble:ArchivePreamble?
                var error:String?
            }
            struct Inventory:Encodable {
                let files:[FileDiagnostic]
                let filesTotal:Int
                let scope:String
            }
            // Only selected headers are needed for checkpoint and history errors.
            // Bound each header read and the JSON output independently of file size.
            let inspect=Set((Array(names.prefix(1))+pending+(q[0][2].map{[$0]} ?? [])+Array(names.suffix(1))).prefix(16))
            var records:[FileDiagnostic]=[],diagnosticBytes=0
            let budget=Int(min(limit/4,1024*1024)),encoder=JSONEncoder()
            for name in names.prefix(10000) where name != "manifest.json" {
                var record=FileDiagnostic(name:name)
                do {
                    try ArchiveIO.filename(name)
                    let file=root.appendingPathComponent(name)
                    record.bytes=try ArchiveIO.regularFile(file)
                    if inspect.contains(name) { record.preamble=try ArchivePreamble.read(file:file,maximumEventBytes:64*1024) }
                } catch { record.error=String(describing:error) }
                let bytes=try encoder.encode(record).count+2
                if diagnosticBytes+bytes > budget { break }
                diagnosticBytes += bytes;records.append(record)
            }
            let inventory=working.appendingPathComponent("archive-inventory.json")
            try ArchiveIO.write(Inventory(files:records,filesTotal:names.count,
                scope:"file sizes plus selected preambles; not full validation; header limit 64 KiB; inventory limit 1 MiB or one quarter of bundle limit"),to:inventory)
            try include(inventory,as:"archive/inventory.json")
        }
        let relay=state.appendingPathComponent("relay.frames")
        if let bytes=try? ArchiveIO.regularFile(relay),let durable,bytes > durable {
            omitted.append("relay.frames includes unjournaled tail at byte \(durable); tail is evidence, not committed progress")
        }
        try include(relay,as:"relay.frames")
        // Keep failure context before unrelated archive payload. Each excerpt retains
        // original offsets. It is diagnostic data, not a standalone replay file.
        for (index,input) in archiveInputs.prefix(16).enumerated() {
            let (name,path)=input
            do {
                _ = try ArchiveIO.regularFile(path)
                let available=limit > total+131072 ? limit-total-131072 : 0
                let budget=min(c.supportBundle.binlogContextBytes ?? 4*1024*1024,available)
                guard budget >= 4096 else { omitted.append("archive/"+name+": size limit; original file retained locally");continue }
                let ranges=archiveRanges[name] ?? [4..<4]
                let excerpt=try BinlogExcerpt.collect(path,to:working,prefix:"binlog-\(index)",focus:ranges[0],maximumBytes:budget)
                for file in excerpt.files { try include(file,as:"archive/"+file.lastPathComponent) }
                if !excerpt.complete { omitted.append("archive/"+name+": partial file; original byte ranges are in the excerpt JSON") }
                if ranges.count > 1 { omitted.append("archive/"+name+": additional pending groups are in state.sqlite and relay.frames") }
            } catch { omitted.append("archive/"+name+": unavailable (\(error))") }
        }
        for (i,path) in (c.supportBundle.logs ?? []).enumerated() { try include(URL(fileURLWithPath:path),as:"logs/\(i).log") }
        let index=working.appendingPathComponent("bundle.json")
        struct Index:Encodable { let version:Int;let containsCustomerData:Bool;let files:[Entry];let omissions:[String] }
        try ArchiveIO.write(Index(version:1,containsCustomerData:true,files:entries,omissions:omitted),to:index)
        let indexSize=try ArchiveIO.regularFile(index)
        try require(indexSize+1024 <= limit-total,"support bundle index exceeds size limit")
        paths.append(("bundle.json",index))
        if c.supportBundle.format == .directory {
            let contents=working.appendingPathComponent("contents")
            try fm.createDirectory(at:contents,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            for (name,path) in paths {
                let copy=contents.appendingPathComponent(name)
                try fm.createDirectory(at:copy.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try copyFile(path,to:copy)
            }
            try fm.moveItem(at:contents,to:output)
        } else {
            let tar=working.appendingPathComponent("bundle.tar")
            try writeTar(paths,to:tar)
            try require(ArchiveIO.regularFile(tar) <= limit,"support bundle exceeds size limit")
            try fm.moveItem(at:tar,to:output)
        }
        return Summary(output:output.path,files:paths.count,omitted:omitted)
    }

    /// Copy bytes rather than link to mutable state or caller-supplied logs.
    private static func copyFile(_ source:URL,to destination:URL) throws {
        let size=try ArchiveIO.regularFile(source)
        guard FileManager.default.createFile(atPath:destination.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw ApplyError("cannot create support file") }
        let input=try FileHandle(forReadingFrom:source),out=try FileHandle(forWritingTo:destination)
        defer { try? input.close();try? out.close() }
        var remaining=size
        while remaining > 0 {
            let data=try input.read(upToCount:Int(min(remaining,1024*1024))) ?? Data()
            try require(!data.isEmpty,"support input truncated during collection")
            try out.write(contentsOf:data);remaining -= UInt64(data.count)
        }
        try require((try input.read(upToCount:1) ?? Data()).isEmpty,"support input grew during collection")
        try out.synchronize()
    }
    /// Portable uncompressed ustar avoids requiring a shell, tar or gzip in the
    /// statically linked runtime image. Files are streamed, never loaded whole.
    private static func writeTar(_ paths:[(String,URL)],to destination:URL) throws {
        guard FileManager.default.createFile(atPath:destination.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw ApplyError("cannot create support archive") }
        let out=try FileHandle(forWritingTo:destination);defer { try? out.close() }
        for (name,path) in paths {
            let size=try ArchiveIO.regularFile(path)
            try require(name.utf8.count <= 100 && size < 8*1024*1024*1024,"support tar entry exceeds ustar limits")
            var header=Data(repeating:0,count:512)
            func field(_ value:String,_ offset:Int,_ width:Int) {
                let bytes=Array(value.utf8);header.replaceSubrange(offset..<offset+min(width,bytes.count),with:bytes.prefix(width))
            }
            field(name,0,100);field("0000600",100,8);field("0000000",108,8);field("0000000",116,8)
            field(String(repeating:"0",count:11-String(size,radix:8).count)+String(size,radix:8),124,12)
            field("00000000000",136,12);field("        ",148,8);field("0",156,1);field("ustar",257,6);field("00",263,2)
            let sum=header.reduce(0) { $0+Int($1) }
            field(String(format:"%06o",sum)+"\0 ",148,8)
            try out.write(contentsOf:header)
            let input=try FileHandle(forReadingFrom:path);defer { try? input.close() }
            var remaining=size
            while remaining > 0 {
                let data=try input.read(upToCount:Int(min(remaining,1024*1024))) ?? Data()
                try require(!data.isEmpty,"support input truncated during collection")
                try out.write(contentsOf:data);remaining -= UInt64(data.count)
            }
            try require((try input.read(upToCount:1) ?? Data()).isEmpty,"support input grew during collection")
            try out.write(contentsOf:Data(repeating:0,count:Int((512-size%512)%512)))
        }
        try out.write(contentsOf:Data(repeating:0,count:1024));try out.synchronize()
    }
}
