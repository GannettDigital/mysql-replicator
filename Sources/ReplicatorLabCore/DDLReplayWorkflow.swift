import Foundation

extension SharedCorrectness.Run {
    /// Replay a live DDL workload from its database baseline. Stop at a saved
    /// transaction boundary, then resume with an unreachable source.
    func replayDDLWorkflow(_ label:String,stopAfter:Int,from start:Boundary,to end:Boundary) throws {
        let original=f.config
        defer {f.config=original}
        var config=LabIsolatedApply(f).configuration(label+"-replay",at:start,count:stopAfter)
        var source=config["source"] as! [String:Any]
        source.removeValue(forKey:"stopAfterTransactions")
        config["source"]=source
        config["archive"]=["directory":"/evidence/"+label+"-archive","firstFile":start.file]
        f.config=config
        func invoke(_ label:String,_ command:String,initialize:Bool=false) throws -> [String:Any] {
            try f.installConfig(label)
            let client=try f.startClient(label,arguments:[command,"--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
            let exit=try f.runner.run(["docker","wait",client],timeout:120).text
            let logs=try f.docker(["logs",client])
            try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
            try require(exit == "0","DDL archive command failed; inspect "+label+".ndjson and support bundle")
            let bytes=command == "replay" ? logs.stderr : logs.stdout
            guard let line=bytes.split(separator:10).last,let result=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else {throw LabError("missing DDL archive summary")}
            return result
        }
        _ = try invoke(label+"-fetch","fetch")
        _ = try f.sql(.target,"SET sql_log_bin=0; DROP DATABASE ddlcompat; CREATE DATABASE ddlcompat CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
        source["host"]="127.0.0.1";source["port"]=1
        source.removeValue(forKey:"passwordEnvironment");source.removeValue(forKey:"password")
        source["stopAfterTransactions"]=stopAfter;f.config["source"]=source
        let stopped=try invoke(label+"-replay-stop","replay",initialize:true)
        try require(stopped["transactionsApplied"] as? Int == stopAfter,"DDL replay stopped at the wrong transaction")
        source.removeValue(forKey:"stopAfterTransactions");f.config["source"]=source
        let resumed=try invoke(label+"-replay-resume","replay")
        try require(resumed["appliedGTIDSet"] as? String == end.gtids,"DDL replay checkpoint differs")
        _ = try compare("ddlcompat")
    }
}
