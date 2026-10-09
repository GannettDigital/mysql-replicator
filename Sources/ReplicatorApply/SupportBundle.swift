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
        public let output: String
        public let maximumBytes: UInt64?
        public let logs: [String]?
    }
    public let stateDirectory: String
    public let supportBundle: Options
    public let archive: ArchiveConfiguration?
}

public enum SupportBundle {
    public struct Summary: Encodable {
        public let output: String
        public let containsCustomerData = true
        public let files: Int
        public let omitted: [String]
    }
    private struct Entry: Encodable {
        let name: String
        let bytes: UInt64
        let sha256: String
    }
    public static func run(configuration c:SupportBundleConfiguration,redactedConfiguration:Data,version:String) throws -> Summary {
        let fm=FileManager.default, state=URL(fileURLWithPath:c.stateDirectory).standardizedFileURL
        let output=URL(fileURLWithPath:c.supportBundle.output).standardizedFileURL
        let limit=c.supportBundle.maximumBytes ?? 2*1024*1024*1024
        try require(!c.stateDirectory.isEmpty && !c.supportBundle.output.isEmpty, "support bundle requires stateDirectory and output")
        try require(limit >= 1024*1024,"support bundle maximumBytes must be at least 1 MiB")
        try require(!fm.fileExists(atPath:output.path),"support bundle output already exists")
        try require(!output.path.hasPrefix(state.path+"/"),"support bundle output must be outside the state directory")
        let fd=open(state.appendingPathComponent("writer.lock").path,O_RDONLY|O_NOFOLLOW)
        try require(fd >= 0,"existing state writer lock is required")
        let lock=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer { try? lock.close() }
        try require(flock(fd,LOCK_EX|LOCK_NB) == 0,"stop the applier before collecting a support bundle; state has an active writer")
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
        let q=try statements.query("SELECT lifecycle,durable_relay_length,applied_file,active_gtid FROM state WHERE id=1")
        try require(q.count == 1,"missing support state row")
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
        let relay=state.appendingPathComponent("relay.frames")
        if let bytes=try? ArchiveIO.regularFile(relay),let durable,bytes > durable {
            omitted.append("relay.frames includes unjournaled tail at byte \(durable); tail is evidence, not committed progress")
        }
        try include(relay,as:"relay.frames")
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
            let pending=try statements.query("SELECT DISTINCT source_file FROM groups WHERE status='PENDING' ORDER BY sequence").compactMap{$0[0]}
            let selected=Set(names)
            let preferred=(pending+(q[0][2].map{[$0]} ?? [])).filter { selected.contains($0) }+names.reversed()
            var seen=Set<String>()
            for name in preferred where name != "manifest.json" && seen.insert(name).inserted {
                do { try ArchiveIO.filename(name);try include(root.appendingPathComponent(name),as:"archive/"+name) }
                catch { omitted.append("archive input rejected: \(name)") }
            }
        }
        for (i,path) in (c.supportBundle.logs ?? []).enumerated() { try include(URL(fileURLWithPath:path),as:"logs/\(i).log") }
        let index=working.appendingPathComponent("bundle.json")
        struct Index:Encodable { let version:Int;let containsCustomerData:Bool;let files:[Entry];let omissions:[String] }
        try ArchiveIO.write(Index(version:1,containsCustomerData:true,files:entries,omissions:omitted),to:index)
        let indexSize=try ArchiveIO.regularFile(index)
        try require(indexSize+1024 <= limit-total,"support bundle index exceeds size limit")
        paths.append(("bundle.json",index))
        let tar=working.appendingPathComponent("bundle.tar")
        try writeTar(paths,to:tar)
        try require(ArchiveIO.regularFile(tar) <= limit,"support bundle exceeds size limit")
        try fm.moveItem(at:tar,to:output)
        return Summary(output:output.path,files:paths.count,omitted:omitted)
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
