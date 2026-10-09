import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO
import ReplicatorCodec

/// Finite raw downloads. Read only files/sizes listed at the beginning; do not
/// follow a growing tip. No semantic row decoding is needed to preserve evidence.
public enum ArchiveFetch {
    public static func run(source:CaptureConfiguration,password:String,archive:ArchiveConfiguration,
                           contract:SourceContract,cancellation:CaptureCancellation = .init()) throws -> ArchiveManifest {
        _ = try source.validate(); try archive.validate()
        guard archive.files == nil else { throw CaptureError("archive.files is for external replay; fetch uses archive.firstFile") }
        let directory=URL(fileURLWithPath:archive.directory).standardizedFileURL
        guard !FileManager.default.fileExists(atPath:directory.path) else { throw CaptureError("fetch requires a new archive directory; incomplete downloads are never overwritten") }
        let group=MultiThreadedEventLoopGroup(numberOfThreads:1); defer { try? group.syncShutdownGracefully() }
        func connect() throws -> MySQLConnection {
            var tls=TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .fullVerification
            if let ca=source.caFile { tls.trustRoots = .file(ca) }
            return try MySQLConnection.connect(to:SocketAddress.makeAddressResolvingHost(source.host,port:source.port),username:source.username,database:"",password:password,tlsConfiguration:tls,serverHostname:source.serverHostname,requireTLS:true,handshakeTimeout:.seconds(10),on:group.next()).wait()
        }
        func query(_ c:MySQLConnection,_ sql:String) throws -> [MySQLRow] {
            let timer=c.eventLoop.scheduleTask(in:.seconds(30)) { _ = c.close() }; defer { timer.cancel() }
            return try c.simpleQuery(sql).wait()
        }
        let listing=try connect(); defer { try? listing.close().wait() }
        let keys=["gtid_mode","enforce_gtid_consistency","binlog_format","binlog_row_image","binlog_checksum","lower_case_table_names"]
        let sql="SELECT @@server_uuid AS source_uuid,VERSION() AS version,"+keys.map { "@@GLOBAL.\($0) AS \($0)" }.joined(separator:",")
        guard let identity=try query(listing,sql).first,
              identity.column("source_uuid")?.string?.lowercased() == source.sourceUUID.lowercased(),
              let version=identity.column("version")?.string,version.hasPrefix(contract.rawValue) else { throw CaptureError("fetch source identity/version differs from profile") }
        let settings=Dictionary(uniqueKeysWithValues:keys.map { ($0,identity.column($0)?.string ?? "") })
        guard settings["gtid_mode"] == "ON",settings["enforce_gtid_consistency"] == "ON",settings["binlog_format"] == "ROW",settings["binlog_row_image"] == "FULL",settings["binlog_checksum"] == "CRC32" else { throw CaptureError("fetch source settings differ from supported profile") }
        let rows=try query(listing,"SHOW BINARY LOGS")
        var files:[(String,UInt64)]=[], total:UInt64=0
        let first=archive.firstFile ?? source.start.file
        var selected=first == nil
        for row in rows {
            guard let name=row.column("Log_name")?.string,let text=row.column("File_size")?.string,let size=UInt64(text),size>4 else { throw CaptureError("invalid source binlog inventory") }
            if name == first { selected=true }
            if !selected { continue }
            try ArchiveIO.filename(name)
            guard files.count < 10000,size <= archive.byteLimit-total else { throw CaptureError("fetch exceeds archive file/byte limit") }
            files.append((name,size));total += size
        }
        guard selected,!files.isEmpty else { throw CaptureError("requested first binlog is unavailable or purged") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        // Presence of this marker, with no manifest, means the archive is not usable.
        try ArchiveIO.write(["status":"incomplete"],to:directory.appendingPathComponent("incomplete.json"))
        try ArchiveIO.syncDirectory(directory)
        try ArchiveIO.syncDirectory(directory.deletingLastPathComponent())
        var entries:[ArchiveManifest.File]=[]
        for (name,size) in files {
            if cancellation.isCancelled { throw CaptureCancelled() }
            let connection=try connect(); defer { try? connection.close().wait() }
            guard try query(connection,"SELECT @@server_uuid AS uuid").first?.column("uuid")?.string?.lowercased() == source.sourceUUID.lowercased() else { throw CaptureError("source identity changed during fetch") }
            _ = try query(connection,contract.dumpSessionSQL)
            let maximum=Int(source.maximumEventBytes ?? 4*1024*1024)
            let queue=PacketQueue(byteLimit:maximum+256*1024), channel=connection.channel
            try channel.setOption(ChannelOptions.autoRead,value:false).wait()
            try channel.setOption(ChannelOptions.maxMessagesPerRead,value:1).wait()
            try channel.setOption(ChannelOptions.recvAllocator,value:FixedSizeRecvByteBufferAllocator(capacity:64*1024)).wait()
            let old=try channel.pipeline.handler(type:ByteToMessageHandler<MySQLPacketDecoder>.self).wait()
            let strict=ByteToMessageHandler(DumpPacketDecoder(maximumMessageBytes:maximum+1),maximumBufferSize:maximum+65536)
            try channel.pipeline.addHandler(strict,position:.before(old)).wait()
            try channel.pipeline.addHandler(DumpReadCompletion(queue:queue),position:.before(strict)).wait()
            try channel.pipeline.removeHandler(old).wait()
            let command=DumpCommand(request:try DumpStart.position(file:name,position:4).packet(serverID:source.serverID,nonBlocking:true),receive:queue.push)
            connection.send(command,logger:connection.logger).whenComplete { queue.finish($0.mapError(sourceTransportFailure)) }
            let path=directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath:path.path,contents:Data([0xfe,0x62,0x69,0x6e]),attributes:[.posixPermissions:0o600]) else { throw CaptureError("cannot create archived binlog") }
            let out=try FileHandle(forWritingTo:path); defer { try? out.close() }; try out.seekToEnd()
            var offset:UInt64=4, announced=false
            while offset < size {
                guard let frame=try queue.next(timeout:TimeInterval(source.idleTimeoutSeconds ?? 15),cancellation:cancellation,requestRead:{ channel.eventLoop.execute { channel.read() } }) else { throw CaptureError("source EOF before captured archive boundary") }
                guard frame.count >= 23 else { throw CaptureError("short raw download event") }
                if frame[4] == 4 && ArchiveIO.read(frame,at:17,as:UInt16.self) & 0x20 != 0 {
                    guard frame.count >= 31,!announced,offset == 4,
                          ArchiveIO.read(frame,at:19,as:UInt64.self) == 4,
                          String(decoding:frame[27..<frame.count-4],as:UTF8.self) == name,
                          ArchiveIO.crc32(Data(frame.dropLast(4))) == ArchiveIO.read(frame,at:frame.count-4,as:UInt32.self) else { throw CaptureError("unexpected fetch file announcement") }
                    announced=true;continue
                }
                let length=ArchiveIO.read(frame,at:9,as:UInt32.self)
                guard announced,Int(length) == frame.count,UInt64(frame.count) <= size-offset,
                      UInt64(ArchiveIO.read(frame,at:13,as:UInt32.self)) == offset+UInt64(frame.count),
                      (offset == 4) == (frame[4] == 15) else { throw CaptureError("raw download differs from captured file boundary") }
                try out.write(contentsOf:frame);offset += UInt64(frame.count)
            }
            try out.synchronize();try out.close();try? connection.close().wait()
            // CRC and framing validation does not limit which column types may
            // be downloaded, and detects truncation before publishing a manifest.
            try ArchiveFileReader(file:path,maximumEventBytes:UInt32(maximum)).scan { _,_ in }
            entries.append(.init(name:name,bytes:size,sha256:try ArchiveIO.hash(path)))
        }
        let manifest=ArchiveManifest(version:1,sourceUUID:source.sourceUUID,sourceVersion:version,settings:settings,files:entries,capturedAt:ISO8601DateFormatter().string(from:Date()))
        try ArchiveIO.write(manifest,to:directory.appendingPathComponent("manifest.json"))
        let handle=try FileHandle(forWritingTo:directory.appendingPathComponent("manifest.json"));try handle.synchronize();try handle.close()
        try ArchiveIO.syncDirectory(directory)
        try FileManager.default.removeItem(at:directory.appendingPathComponent("incomplete.json"))
        try ArchiveIO.syncDirectory(directory)
        return manifest
    }
}
