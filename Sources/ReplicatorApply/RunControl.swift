import Foundation
import ReplicatorCapture

struct ApplyReloadRequested: Error {}

/// The socket thread only submits requests and reads published snapshots. The
/// apply coordinator alone changes limits, accesses SQLite, and acknowledges a
/// reload after its active executor has joined and unapplied capture is dropped.
public final class RunControl: @unchecked Sendable {
    private let condition=NSCondition()
    private let drain: CaptureCancellation
    private let reload: () throws -> StopConditions
    private let instance=UUID().uuidString
    private var socket: ControlSocket?
    private var progress: ApplySummary?
    private var limits: StopConditions
    private var finished=false, pending=false
    private var ticket=0, completed=0, generation=1
    private var reloadError: String?
    public init(limits: StopConditions, drain: CaptureCancellation, reload: @escaping () throws -> StopConditions) {
        self.limits=limits;self.drain=drain;self.reload=reload
    }
    func start(directory: URL) throws { socket=try ControlSocket(directory:directory,handle:request) }
    func publish(_ progress: ApplySummary) {
        condition.lock();defer { condition.unlock() }
        self.progress=progress;condition.broadcast()
    }
    var reloadRequested: Bool {
        condition.lock();defer { condition.unlock() };return pending
    }
    func candidate() throws -> StopConditions { try reload() }
    func acknowledge(_ result: Result<StopConditions,Error>) {
        condition.lock();defer { condition.unlock() }
        switch result {
        case .success(let limits):self.limits=limits;generation += 1;reloadError=nil
        case .failure(let error):reloadError=String(describing:error)
        }
        pending=false;completed=ticket;condition.broadcast()
    }
    func finish(_ summary: ApplySummary) {
        condition.lock();progress=summary;finished=true;condition.broadcast();condition.unlock()
        socket?.close();socket=nil
    }
    private struct Reply: Encodable {
        let ok: Bool
        let command: String
        let error: String?
        let pid: Int32
        let instance: String
        let running: Bool
        let configurationGeneration: Int
        let limits: StopConditions
        let progress: ApplySummary?
    }
    private func reply(_ command: String,error: String? = nil) -> Data {
        let reply=Reply(ok:error == nil,command:command,error:error,pid:ProcessInfo.processInfo.processIdentifier,
            instance:instance,running:!finished,configurationGeneration:generation,limits:limits,progress:progress)
        return (try? JSONEncoder().encode(reply)) ?? ControlSocket.error("cannot encode control status")
    }
    private func request(_ request: ControlRequest) -> Data {
        condition.lock();defer { condition.unlock() }
        if request.command == "status" { return reply(request.command) }
        if finished { return reply(request.command,error:"process is stopping or stopped") }
        let deadline=Date().addingTimeInterval(TimeInterval(request.timeoutSeconds))
        if request.command == "stop" {
            drain.cancel()
            while !finished {
                guard condition.wait(until:deadline) else { return reply("stop",error:"stop timed out; graceful drain is still requested") }
            }
            return reply("stop",error:progress?.lifecycle == "STOPPED" ? nil : "process did not stop cleanly; inspect saved state")
        }
        guard !pending && !drain.isCancelled else { return reply("reload",error:"another control operation is pending") }
        pending=true;ticket += 1;let requested=ticket
        while completed < requested && !finished {
            guard condition.wait(until:deadline) else { return reply("reload",error:"reload acknowledgment timed out; request may still complete") }
        }
        if completed < requested { return reply("reload",error:"process stopped before reload completed") }
        return reply("reload",error:reloadError)
    }
}
