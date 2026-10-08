import Foundation
import NIOCore
import NIOPosix

public struct ControlRequest: Codable {
    public let command: String
    public let timeoutSeconds: Int
    public init(command: String, timeoutSeconds: Int = 60) {
        self.command=command; self.timeoutSeconds=timeoutSeconds
    }
    func validate() throws {
        try require(["status","stop","reload"].contains(command),"unknown control command")
        try require((1...86400).contains(timeoutSeconds),"control timeout must be 1 to 86400 seconds")
    }
}

/// Local request/reply transport. The caller holds the state writer lock for
/// the server's entire lifetime, including stale-socket cleanup.
final class ControlSocket {
    private let group=MultiThreadedEventLoopGroup(numberOfThreads:1)
    private var listener: Channel?
    private let path: String
    private let jobs=DispatchGroup()
    private let slots=DispatchSemaphore(value:8)
    init(directory: URL, handle: @escaping (ControlRequest) -> Data) throws {
        path=directory.appendingPathComponent("control.sock").path
        do {
            try require(path.utf8.count <= 103,"stateDirectory is too long for control.sock (maximum socket path: 103 bytes)")
            if FileManager.default.fileExists(atPath:path) {
                let attributes=try FileManager.default.attributesOfItem(atPath:path)
                try require(attributes[.type] as? FileAttributeType == .typeSocket,"refusing to replace a non-socket control path")
                try FileManager.default.removeItem(atPath:path)
            }
            listener=try ServerBootstrap(group:group).childChannelInitializer { [jobs,slots] channel in
                channel.pipeline.addHandler(ControlRequestHandler(jobs:jobs,slots:slots,handle:handle))
            }.bind(unixDomainSocketPath:path).wait()
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)
        } catch {
            try? listener?.close().wait();try? group.syncShutdownGracefully();throw error
        }
    }
    func close() {
        try? listener?.close().wait()
        jobs.wait() // RunControl.finish releases all outstanding stop/reload waiters first.
        try? group.syncShutdownGracefully()
        try? FileManager.default.removeItem(atPath:path)
    }
    static func error(_ message: String) -> Data {
        // Messages here are fixed diagnostics, never configuration contents.
        (try? JSONSerialization.data(withJSONObject:["ok":false,"error":message],options:.sortedKeys)) ?? Data()
    }
}

private final class ControlRequestHandler: ChannelInboundHandler {
    typealias InboundIn=ByteBuffer
    private var bytes=Data(), dispatched=false
    private var timeout: Scheduled<Void>?
    private let jobs: DispatchGroup, slots: DispatchSemaphore
    private let handle: (ControlRequest) -> Data
    init(jobs: DispatchGroup, slots: DispatchSemaphore, handle: @escaping (ControlRequest) -> Data) {
        self.jobs=jobs;self.slots=slots;self.handle=handle
    }
    func channelActive(context: ChannelHandlerContext) {
        timeout=context.eventLoop.scheduleTask(in:.seconds(5)) { context.close(promise:nil) }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !dispatched else { return }
        var buffer=unwrapInboundIn(data)
        guard bytes.count+buffer.readableBytes <= 1024 else { context.close(promise:nil);return }
        bytes.append(contentsOf:buffer.readBytes(length:buffer.readableBytes) ?? [])
        guard bytes.last == 10 else { return }
        dispatched=true;timeout?.cancel()
        let request: ControlRequest
        do { request=try JSONDecoder().decode(ControlRequest.self,from:bytes);try request.validate() }
        catch { context.close(promise:nil);return }
        guard slots.wait(timeout:.now()) == .success else { context.close(promise:nil);return }
        let channel=context.channel
        jobs.enter()
        DispatchQueue.global().async { [jobs,slots,handle] in
            defer { slots.signal();jobs.leave() }
            let response=handle(request)+Data([10])
            let buffer=channel.allocator.buffer(bytes:response)
            let timeout=channel.eventLoop.scheduleTask(in:.seconds(5)) { channel.close(promise:nil) }
            defer { timeout.cancel() }
            try? channel.writeAndFlush(buffer).wait()
            try? channel.close().wait()
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise:nil) }
    func channelInactive(context: ChannelHandlerContext) { timeout?.cancel();context.fireChannelInactive() }
}

public enum ControlClient {
    /// The returned JSON includes the acknowledged operation result. A timeout
    /// does not cancel a stop/reload already accepted by the running process.
    public static func request(_ request: ControlRequest, stateDirectory: String) throws -> Data {
        try request.validate()
        let group=MultiThreadedEventLoopGroup(numberOfThreads:1);defer { try? group.syncShutdownGracefully() }
        let loop=group.next(),result=loop.makePromise(of:Data.self)
        let handler=ControlResponseHandler(result:result)
        let channel: Channel
        do {
            channel=try ClientBootstrap(group:group).connectTimeout(.seconds(5)).channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }.connect(unixDomainSocketPath:URL(fileURLWithPath:stateDirectory).appendingPathComponent("control.sock").path).wait()
        } catch {
            try? loop.submit { handler.fail(error) }.wait()
            throw error
        }
        defer { try? channel.close().wait() }
        let timer=loop.scheduleTask(in:.seconds(Int64(request.timeoutSeconds)+2)) { channel.close(promise:nil) }
        defer { timer.cancel() }
        try channel.writeAndFlush(channel.allocator.buffer(bytes:JSONEncoder().encode(request)+Data([10]))).wait()
        return try result.futureResult.wait()
    }
}

private final class ControlResponseHandler: ChannelInboundHandler {
    typealias InboundIn=ByteBuffer
    private var bytes=Data(),done=false
    private let result: EventLoopPromise<Data>
    init(result: EventLoopPromise<Data>) { self.result=result }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        var buffer=unwrapInboundIn(data)
        guard bytes.count+buffer.readableBytes <= 4*1024*1024 else { fail(ApplyError("control response exceeds limit"));context.close(promise:nil);return }
        bytes.append(contentsOf:buffer.readBytes(length:buffer.readableBytes) ?? [])
        if bytes.last == 10 { done=true;result.succeed(bytes) }
    }
    func fail(_ error: Error) { if !done { done=true;result.fail(error) } }
    func channelInactive(context: ChannelHandlerContext) {
        fail(ApplyError("control connection closed before acknowledgment; operation may still be running"))
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext,error:Error) { fail(error);context.close(promise:nil) }
}
