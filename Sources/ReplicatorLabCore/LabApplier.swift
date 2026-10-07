import Foundation

/// Shell container lifetime is separate from the replication process. Supports
/// sessions created before demo-up provisioned an idle applier, without reseeding.
final class LabApplier {
    let fixture: LabFixture
    var name: String { fixture.h.project+"-applier" }
    init(_ fixture: LabFixture) { self.fixture=fixture }
    func containerState() throws -> String {
        let ids=try fixture.docker(["ps","-aq","--filter","name=^/"+name+"$"]).text
        if ids.isEmpty { return "NOT_CREATED" }
        return try fixture.docker(["inspect",name,"--format","{{.State.Status}}"]).text
    }
    func pids() throws -> [String] {
        guard try containerState() == "running" else { return [] }
        // Docker Desktop can expose an emulator as exe. Inspect its executable
        // argument rather than searching entire command lines or trusting PID files.
        let script = #"""
        for directory in /proc/[0-9]*; do
            executable=$(readlink "$directory/exe")
            case "$executable" in
                /usr/local/bin/mysql-replicator) basename "$directory" ;;
                */qemu-*|*/rosetta)
                    first= second=
                    { IFS= read -r -d '' first; IFS= read -r -d '' second; } < "$directory/cmdline" 2>/dev/null
                    if [ "$second" = /usr/local/bin/mysql-replicator ]; then basename "$directory"; fi
                    ;;
            esac
        done
        """#
        let values=try fixture.docker(["exec",name,"/bin/bash","-c",script]).text.split(separator:"\n").map(String.init)
        try require(values.allSatisfy{!$0.isEmpty && $0.allSatisfy(\.isNumber)},"invalid applier PID")
        return values
    }
    func ensureIdleContainer() throws {
        let state=try containerState()
        if state == "running" { return } // Never replace a live foreground session.
        if state != "NOT_CREATED" {
            let entry=try fixture.docker(["inspect",name,"--format","{{json .Config.Entrypoint}}"] ).text
            if entry.contains("/bin/sleep") { _ = try fixture.docker(["start",name]); return }
            // Older sessions ran the applier as PID 1. Archive it before replacing
            // its exited container; all config/checkpoints live in the same volume.
            try archiveLogs()
            _ = try fixture.docker(["rm",name])
        }
        _ = try fixture.docker(["run","-d","--init","--name",name,"--platform","linux/amd64","--network",fixture.h.project+"_fixture","--mount","type=volume,src=\(fixture.volume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only","--entrypoint","/bin/sleep"]+CodeCoverage.environment(enabled:fixture.codeCoverage,label:"continuous")+[fixture.image,"infinity"])
    }
    func logs(tail: Bool = false) throws -> CommandResult {
        if try containerState() == "running" {
            let reader=tail ? "tail -n 2" : "cat"
            return try fixture.docker(["exec",name,"/bin/sh","-c","if [ -f /evidence/applier.ndjson ]; then \(reader) /evidence/applier.ndjson; fi; if [ -f /evidence/applier.stderr ]; then \(reader) /evidence/applier.stderr >&2; fi"])
        }
        if try containerState() != "NOT_CREATED" { return try fixture.docker(["logs",name]) }
        return CommandResult(stdout:Data(),stderr:Data(),status:0)
    }
    func latestProgress() throws -> [String:Any]? {
        // Bound polling output even when a long demo has produced many summaries.
        let result=try fixture.docker(["exec",name,"/bin/sh","-c","if [ -f /evidence/applier.ndjson ]; then tail -n 1 /evidence/applier.ndjson; fi"])
        guard let line=result.stdout.split(separator:10).last else { return nil }
        return try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any]
    }
    func archiveLogs() throws {
        let data=try logs(), label="applier-"+runID()
        if !data.stdout.isEmpty { try data.stdout.write(to:fixture.output.appendingPathComponent(label+".ndjson")) }
        if !data.stderr.isEmpty { try data.stderr.write(to:fixture.output.appendingPathComponent(label+".stderr")) }
    }
    func hasState() throws -> Bool {
        let volumes=try fixture.docker(["volume","ls","--format","{{.Name}}"] ).text.split(separator:"\n")
        if !volumes.contains(Substring(fixture.volume)) { return false }
        let result=try fixture.docker(["run","--rm","--platform","linux/amd64","--network","none","--mount","type=volume,src=\(fixture.volume),dst=/evidence","--entrypoint","/usr/bin/test",fixture.image,"-f","/evidence/state/state.sqlite"],checked:false)
        try require(result.status == 0 || result.status == 1,"cannot inspect demo state")
        return result.status == 0
    }
    func start(initialize: Bool) throws {
        try archiveLogs(); try ensureIdleContainer()
        let command="exec /usr/local/bin/mysql-replicator run --config /evidence/apply.yaml"+(initialize ? " --initialize" : "")+" > /evidence/applier.ndjson 2> /evidence/applier.stderr"
        let label="apply-"+runID()
        if fixture.codeCoverage { fixture.coverageInvocations.append(["label":label,"exit_code":0]) }
        _ = try fixture.docker(["exec","-d"]+CodeCoverage.environment(enabled:fixture.codeCoverage,label:label)+[name,"/bin/sh","-c",command])
    }
    func drain() throws {
        let ids=try pids()
        if ids.isEmpty { return }
        _ = try fixture.docker(["exec",name,"/bin/sh","-c",#"kill -USR1 "$@""#,"reverse-demo-stop"]+ids)
        let deadline=Date().addingTimeInterval(30)
        while try !pids().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval:0.1) }
        try require(try pids().isEmpty,"applier did not drain; retaining the demo for inspection")
    }
}
