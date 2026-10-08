import Foundation

/// A fresh durable state per experiment, with explicit restart pairs. Shared
/// scenarios use this after draining the continuous correctness writer.
final class LabIsolatedApply {
    let f: LabFixture
    let base: [String:Any]
    init(_ fixture: LabFixture) { f=fixture; base=fixture.config }
    func configuration(_ label: String, at boundary: Boundary, count: Int) -> [String:Any] {
        var config=base, source=config["source"] as! [String:Any]
        source["start"]=f.variant.start(boundary); source["stopAfterTransactions"]=count
        config["source"]=source; config["stateDirectory"]="/evidence/"+label
        return config
    }
    func start(_ label: String, config: [String:Any], initialize: Bool = true) throws -> String {
        let original=f.config
        defer { f.config=original }
        f.config=config; try f.installConfig(label)
        return try f.startClient(label,arguments:["run","--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
    }
    func barrier(_ client: String, count: Int) throws {
        let deadline=Date().addingTimeInterval(60)
        repeat {
            let logs=try f.docker(["logs",client])
            if let last=logs.stdout.split(separator:10).last,
               let progress=try JSONSerialization.jsonObject(with:Data(last)) as? [String:Any],
               progress["transactionsApplied"] as? Int == count { return }
            try require(try f.docker(["inspect",client,"--format","{{.State.Running}}"] ).text == "true","applier stopped before barrier: "+String(decoding:logs.stderr,as:UTF8.self))
            Thread.sleep(forTimeInterval:0.1)
        } while Date()<deadline
        throw LabError("isolated applier did not reach transaction \(count)")
    }
    func finish(_ client: String, label: String, config: [String:Any], success: Bool? = nil, reason: String? = nil) throws -> [String:Any] {
        let exit=try f.runner.run(["docker","wait",client],timeout:90).text
        let logs=try f.docker(["logs",client])
        try logs.stdout.write(to:f.output.appendingPathComponent(label+".ndjson"))
        try logs.stderr.write(to:f.output.appendingPathComponent(label+".diagnostic.json"))
        try require((success ?? (reason == nil)) ? exit == "0" : exit != "0","unexpected isolated process exit: "+exit)
        guard let line=logs.stderr.split(separator:10).last,
              let result=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing isolated apply summary") }
        if let reason { try require((result["reason"] as? String ?? "").contains(reason),"wrong refusal: \(result)") }
        // Preflight rejection can precede state creation. State-reading assertions
        // still require a real snapshot; only copy when it exists in the volume.
        let directory=config["stateDirectory"] as! String
        let exists=try f.docker(["run","--rm","--platform","linux/amd64","--network","none","--mount","type=volume,src=\(f.volume),dst=/evidence","--entrypoint","/usr/bin/test",f.image,"-d",directory],checked:false)
        try require(exists.status == 0 || exists.status == 1,"cannot inspect isolated state directory")
        if exists.status == 0 {
            _ = try f.docker(["cp",f.helper+":"+directory,f.output.appendingPathComponent("snapshot-"+label).path])
        }
        return result
    }
    func state(_ label: String, _ sql: String) throws -> String {
        try f.runner.run(["sqlite3",f.output.appendingPathComponent("snapshot-"+label+"/state.sqlite").path,sql]).text
    }
}
