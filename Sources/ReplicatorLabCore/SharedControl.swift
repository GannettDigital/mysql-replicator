import Foundation

extension SharedCorrectness.Run {
    func runtimeControl() throws {
        guard selects("runtime-control") else { return }
        try reporter.run(QualificationCase("runtime-control","Exact GTID boundaries, live/offline reload, acknowledged drain, and checkpoint resume")) {
            try resetNativeEngine();try f.awaitNative()
            if f.profile.hasOptionalMetadata { _ = try f.sql(.source,"SET GLOBAL binlog_row_metadata="+f.variant.metadata) }
            let seed="SET sql_log_bin=0; DROP DATABASE IF EXISTS control_poc; CREATE DATABASE control_poc CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE TABLE control_poc.aux(id INT PRIMARY KEY,val INT); INSERT INTO control_poc.aux VALUES(0,0)"
            for role in LabProfile.Role.allCases { _ = try f.sql(role,seed) }
            let begin=try f.boundary(),original=f.config
            defer { f.config=original }
            var middle=""
            for i in 1...6 {
                _ = try f.sql(.source,session+"INSERT INTO control_poc.aux VALUES(\(i),\(i))")
                if i == 3 { middle=try f.boundary().gtids }
            }
            try f.awaitNative();let end=try f.boundary()
            var source=original["source"] as! [String:Any]
            source["mode"]="gtid";source["start"]=["file":begin.file,"position":begin.position,"executedGTIDs":begin.gtids]
            source.removeValue(forKey:"stopAfterTransactions")
            f.config["source"]=source;f.config["archive"]=["directory":"/evidence/control-archive","firstFile":begin.file]
            func finish(_ client:String,_ label:String,command:String="replay") throws -> [String:Any] {
                let code=try f.runner.run(["docker","wait",client],timeout:120).text
                let logs=try f.docker(["logs",client])
                try (logs.stdout+logs.stderr).write(to:f.output.appendingPathComponent(label+".ndjson"))
                try require(code == "0","control scenario process failed: "+String(decoding:logs.stderr,as:UTF8.self))
                let bytes=command == "fetch" ? logs.stdout : logs.stderr
                return try JSONSerialization.jsonObject(with:Data(bytes.split(separator:10).last!)) as! [String:Any]
            }
            func start(_ label:String,_ command:String="replay",initialize:Bool=true) throws -> String {
                try f.installConfig(label)
                return try f.startClient(label,arguments:[command,"--config","/evidence/"+label+".yaml"]+(initialize ? ["--initialize"] : []))
            }
            try f.installConfig("control-fetch")
            _ = try finish(f.startClient("control-fetch",arguments:["fetch","--config","/evidence/control-fetch.yaml"]),"control-fetch",command:"fetch")
            source["host"]="127.0.0.1";source["port"]=1;source.removeValue(forKey:"passwordEnvironment");source.removeValue(forKey:"password")
            source["stopAfterGTIDs"]=middle;source["stopAfterTransactions"]=100
            f.config["source"]=source;f.config["stateDirectory"]="/evidence/control-static"
            let partial=try finish(start("control-exact"),"control-exact")
            try require(partial["transactionsApplied"] as? Int == 3 && partial["appliedGTIDSet"] as? String == middle && partial["stopReason"] as? String == "gtidsSatisfied","GTID stop overshot its boundary")
            try require(try f.sql(.target,"SELECT GROUP_CONCAT(id ORDER BY id) FROM control_poc.aux") == "0,1,2,3","later rows were applied after GTID stop")
            let covered=try finish(start("control-covered",initialize:false),"control-covered")
            try require(covered["transactionsApplied"] as? Int == 3 && covered["stopReason"] as? String == "alreadySatisfied","covered GTID stop reapplied work")
            source["stopAfterGTIDs"]=end.gtids;f.config["source"]=source
            _ = try finish(start("control-resume",initialize:false),"control-resume")
            _ = try compare("control_poc")

            var requestNumber=0
            func ctl(_ action:String,_ config:String,ok:Bool=true) throws -> [String:Any] {
                requestNumber += 1
                let result=try f.docker(["run","--rm","--platform","linux/amd64","--network","none","--mount","type=volume,src=\(f.volume),dst=/evidence","--entrypoint","/usr/local/bin/mysql-replicator",f.image,"ctl",action,"--config","/evidence/"+config+".yaml","--timeout","45"],checked:false)
                try (result.stdout+result.stderr).write(to:f.output.appendingPathComponent("ctl-\(requestNumber)-\(action).ndjson"))
                try require((result.status == 0) == ok,"unexpected ctl exit: "+String(decoding:result.stdout+result.stderr,as:UTF8.self))
                return try JSONSerialization.jsonObject(with:result.stdout) as! [String:Any]
            }
            func awaitStatus(_ label:String,active:Bool=false) throws {
                let deadline=Date().addingTimeInterval(30)
                while Date() < deadline {
                    if let status=try? ctl("status",label),let progress=status["progress"] as? [String:Any],progress["lifecycle"] as? String == "RUNNING",
                       !active || (progress["activeBatchTransactions"] as? Int ?? 0) > 0 { return }
                    Thread.sleep(forTimeInterval:0.1)
                }
                throw LabError("control endpoint did not publish expected status")
            }
            let target=try f.h.compose(["ps","-q",f.profile.service(.target)]).text
            func blockWrites() throws {
                _ = try f.docker(["exec","-d","-e","MYSQL_PWD=fixture-root-only",target,"mysql","--no-defaults","-uroot","-e","LOCK TABLES control_poc.aux READ; DO SLEEP(6); UNLOCK TABLES"])
                let deadline=Date().addingTimeInterval(10)
                while try f.sql(.target,"SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO='DO SLEEP(6)'") != "1" {
                    try require(Date() < deadline,"target blocker did not acquire lock");Thread.sleep(forTimeInterval:0.05)
                }
            }
            // Reload while the first batch is actually issued and blocked.
            _ = try f.sql(.target,seed)
            source.removeValue(forKey:"stopAfterGTIDs");source.removeValue(forKey:"stopAfterTransactions")
            f.config["source"]=source;f.config["stateDirectory"]="/evidence/control-reload"
            var batch=f.config["batch"] as? [String:Any] ?? [:];batch["maximumTransactions"]=1;f.config["batch"]=batch
            try blockWrites()
            let replay=try start("control-reload")
            try awaitStatus("control-reload",active:true)
            source["stopAfterGTIDs"]=middle;f.config["source"]=source;try f.installConfig("control-reload")
            let reload=try ctl("reload","control-reload")
            try require(reload["configurationGeneration"] as? Int == 2,"reload was not acknowledged")
            let replayed=try finish(replay,"control-reload")
            try require(replayed["appliedGTIDSet"] as? String == middle && replayed["transactionsApplied"] as? Int == 3,"reload overshot GTID boundary")
            source["stopAfterGTIDs"]=end.gtids;f.config["source"]=source
            _ = try finish(start("control-reload-resume",initialize:false),"control-reload-resume")
            _ = try compare("control_poc")

            // Live idle reload rejects reseeding and past boundaries, then accepts
            // a future limit without resetting the invocation's transaction count.
            source=original["source"] as! [String:Any]
            source["mode"]="gtid";source["start"]=["executedGTIDs":end.gtids];source.removeValue(forKey:"stopAfterTransactions")
            f.config["source"]=source;f.config["stateDirectory"]="/evidence/control-live"
            let live=try start("control-live","run")
            try awaitStatus("control-live")
            var changed=source;changed["start"]=["executedGTIDs":""]
            f.config["source"]=changed;try f.installConfig("control-live")
            let rejected=try ctl("reload","control-live",ok:false)
            try require(rejected["configurationGeneration"] as? Int == 1,"rejected reload changed generation")
            changed=source;changed["stopAfterGTIDs"]=end.gtids
            f.config["source"]=changed;try f.installConfig("control-live")
            _ = try ctl("reload","control-live",ok:false)
            let sid=source["sourceUUID"] as! String
            let interval=end.gtids.split(separator:",").first { $0.hasPrefix(sid+":") }!.split(separator:":").last!
            let next=UInt64(interval.split(separator:"-").last!)!+1
            source["stopAfterGTIDs"]=sid+":\(next)";source["stopAfterTransactions"]=100
            f.config["source"]=source;try f.installConfig("control-live")
            _ = try ctl("reload","control-live")
            _ = try f.sql(.source,session+"INSERT INTO control_poc.aux VALUES(7,7)")
            let liveResult=try finish(live,"control-live",command:"run")
            try require(liveResult["transactionsApplied"] as? Int == 1 && liveResult["stopReason"] as? String == "gtidsSatisfied","live reload/GTID stop differs")

            let beforeStop=try f.boundary()
            source["start"]=["executedGTIDs":beforeStop.gtids];source.removeValue(forKey:"stopAfterGTIDs");source.removeValue(forKey:"stopAfterTransactions")
            f.config["source"]=source;f.config["stateDirectory"]="/evidence/control-stop"
            let stopping=try start("control-stop","run")
            try awaitStatus("control-stop");try blockWrites()
            _ = try f.sql(.source,session+"INSERT INTO control_poc.aux VALUES(8,8)")
            try awaitStatus("control-stop",active:true)
            let stopped=try ctl("stop","control-stop")
            try require((stopped["progress"] as? [String:Any])?["lifecycle"] as? String == "STOPPED","stop returned before clean checkpoint")
            let stopResult=try finish(stopping,"control-stop",command:"run")
            try require(stopResult["stopReason"] as? String == "drainRequested" && stopResult["appliedGTIDSet"] as? String == f.boundary().gtids,"stop lost acknowledged target work")
            try f.awaitNative();_ = try compare("control_poc")
        }
    }
}
