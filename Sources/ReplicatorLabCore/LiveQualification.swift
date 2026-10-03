import Foundation

/// Real MySQL wire qualification using the shipped static Ubuntu CLI. The lab
/// uses mysqlbinlog as its row oracle and YAML for runtime configuration.
public enum LiveQualification {
    public static func run(root: URL, build: Bool = true) throws {
        var native = NativeCase(); native.transaction = false
        let h = NativeHarness(root: root, config: native, artifactCategory: "live-suite")
        let runner = h.runner, output = h.output, tls = output.appendingPathComponent("tls")
        let image = "mysql-replicator-packaging:ubuntu16.04"
        try FileManager.default.createDirectory(at: tls, withIntermediateDirectories: true)
        h.composeOverlays = [root.appendingPathComponent("docker/live/compose.yaml").path]
        h.composeEnvironment = ["REPLICATOR_LIVE_TLS_DIR": tls.path]
        var clients: [String] = [], started = false, failure: Error?
        var report: [String: Any] = ["schema_version":1, "result":"failed", "swift_apply":"pending", "durable_progress":false]
        print("Live capture evidence: \(output.path)")
        func record(_ name: String, _ args: [String], timeout: TimeInterval = 120) throws -> CommandResult {
            let r = try runner.run(args, timeout: timeout, checked: false)
            try r.stdout.write(to: output.appendingPathComponent(name + ".stdout"))
            try r.stderr.write(to: output.appendingPathComponent(name + ".stderr"))
            try require(r.status == 0, "\(name) failed: exit \(r.status); see evidence")
            return r
        }
        func docker(_ args: [String]) throws -> CommandResult { try runner.run(["docker"] + args) }
        func startClient(_ label: String, _ config: [String: Any]) throws -> String {
            try writeYAML(config, to: output.appendingPathComponent(label + ".yaml"))
            let name = h.project + "-" + label; clients.append(name)
            _ = try docker(["run", "-d", "--name", name, "--platform", "linux/amd64", "--network", h.project + "_fixture",
                "--mount", "type=bind,src=\(output.path),dst=/evidence,readonly", "-e", "LIVE_PASSWORD=fixture-capture-only",
                "--entrypoint", "/usr/local/bin/mysql-replicator", image, "inspect", "--source-config", "/evidence/\(label).yaml", "--transactions"])
            return name
        }
        func finishClient(_ name: String, _ label: String, success: Bool) throws -> (Data, [String: Any]) {
            let exit = try runner.run(["docker", "wait", name], timeout: 45).text
            let logs = try docker(["logs", name])
            try logs.stdout.write(to: output.appendingPathComponent(label + ".ndjson"))
            try logs.stderr.write(to: output.appendingPathComponent(label + ".diagnostic.json"))
            try require(success ? exit == "0" : exit != "0", "\(label): unexpected exit \(exit)")
            guard let last = String(decoding:logs.stderr,as:UTF8.self).split(separator:"\n").last,
                  let diagnostic = try JSONSerialization.jsonObject(with:Data(last.utf8)) as? [String:Any] else { throw LabError("\(label): missing structured diagnostic") }
            return (logs.stdout, diagnostic)
        }
        func waitForReaders(_ count: Int) throws -> [String] {
            let deadline = Date().addingTimeInterval(20)
            repeat {
                let ids = try h.sql("source", "SELECT ID FROM information_schema.PROCESSLIST WHERE USER='capture_fixture' AND COMMAND LIKE 'Binlog Dump%' ORDER BY ID").split(separator:"\n").map(String.init)
                if ids.count == count { return ids }
                Thread.sleep(forTimeInterval:0.2)
            } while Date() < deadline
            throw LabError("live readers did not reach dump state")
        }
        do {
            report["reference_decoder"] = try runner.run([h.decoder,"--no-defaults","--version"]).text
            try require((report["reference_decoder"] as? String)?.contains("Ver 8.4.") == true, "MySQL 8.4 mysqlbinlog required")
            if build { _ = try record("build", ["docker","build","--platform","linux/amd64","--target","runtime","-f","docker/packaging/Dockerfile","-t",image,"."], timeout:3600) }
            report["runtime_image"] = try docker(["image","inspect",image,"--format","{{.Id}}"]).text
            _ = try record("ca", ["openssl","req","-x509","-newkey","rsa:2048","-nodes","-sha256","-days","2","-subj","/CN=Replicator Live Test CA","-keyout",tls.appendingPathComponent("ca-key.pem").path,"-out",tls.appendingPathComponent("ca.pem").path])
            _ = try record("csr", ["openssl","req","-newkey","rsa:2048","-nodes","-sha256","-subj","/CN=source","-keyout",tls.appendingPathComponent("server-key.pem").path,"-out",tls.appendingPathComponent("server.csr").path])
            let ext = tls.appendingPathComponent("extensions.cnf")
            try "subjectAltName=DNS:source\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".write(to:ext,atomically:true,encoding:.utf8)
            _ = try record("certificate", ["openssl","x509","-req","-in",tls.appendingPathComponent("server.csr").path,"-CA",tls.appendingPathComponent("ca.pem").path,"-CAkey",tls.appendingPathComponent("ca-key.pem").path,"-CAcreateserial","-days","2","-sha256","-extfile",ext.path,"-out",tls.appendingPathComponent("server.pem").path])
            try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:tls.appendingPathComponent("server-key.pem").path)
            started = true
            let startup = try h.compose(["up","-d","--build","--wait","--wait-timeout","300"],timeout:600)
            try (startup.stdout + startup.stderr).write(to:output.appendingPathComponent("startup.log"))
            _ = try h.sql("source", "CREATE USER 'capture_fixture'@'%' IDENTIFIED BY 'fixture-capture-only' REQUIRE SSL; GRANT REPLICATION SLAVE ON *.* TO 'capture_fixture'@'%'; CREATE USER 'native_fixture'@'%' IDENTIFIED BY 'fixture-native-only' REQUIRE SSL; GRANT REPLICATION SLAVE ON *.* TO 'native_fixture'@'%'")
            for service in h.services {
                let engine = service == "source" ? "InnoDB" : "MyISAM"
                _ = try h.sql(service,"CREATE DATABASE poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE TABLE poc.items(id INT PRIMARY KEY,value VARCHAR(100) NOT NULL,quantity BIGINT UNSIGNED NOT NULL) ENGINE=\(engine); INSERT INTO poc.items VALUES(1,'seed-one',1),(2,'seed-two',2)")
                try require(h.engine(service) == engine && h.rows(service) == Fixture.seed,"seed/engine mismatch")
                try require(h.sql(service,"SELECT @@gtid_mode,@@enforce_gtid_consistency") == (service == "source" ? "ON\tON" : "OFF_PERMISSIVE\tWARN"),"GTID settings mismatch")
            }
            let start = try h.boundary("source"), nativeStart = try h.boundary("native")
            let uuid = try h.sql("source","SELECT @@server_uuid")
            report["start"] = start.json
            _ = try h.sql("native","SET @@GLOBAL.gtid_purged='+\(start.gtids)'; CHANGE REPLICATION SOURCE TO SOURCE_HOST='source',SOURCE_USER='native_fixture',SOURCE_PASSWORD='fixture-native-only',SOURCE_SSL=1,SOURCE_AUTO_POSITION=1; START REPLICA")
            func configuration(_ mode: String, _ id: Int, at boundary: Boundary) -> [String: Any] {
                ["version":1,"host":"source","port":3306,"username":"capture_fixture","passwordEnvironment":"LIVE_PASSWORD","serverHostname":"source","caFile":"/evidence/tls/ca.pem","serverID":id,"sourceUUID":uuid,"mode":mode,
                 "start":["file":boundary.file,"position":boundary.position,"executedGTIDs":boundary.gtids],
                 "tables":[["database":"poc","table":"items","columns":["signed","utf8","unsigned"]]],"stopAfterTransactions":4,"idleTimeoutSeconds":15]
            }
            let positional = configuration("file-position",9001,at:start), gtid = configuration("gtid",9002,at:start)
            let p = try startClient("position",positional), g = try startClient("gtid",gtid)
            _ = try waitForReaders(2)
            _ = try h.sql("source","INSERT INTO poc.items VALUES (3,'inserted',18446744073709551615); UPDATE poc.items SET value='updated' WHERE id=1")
            let beforeRotation = try h.boundary("source")
            _ = try h.sql("source","FLUSH BINARY LOGS")
            let afterRotation = try h.boundary("source")
            _ = try h.sql("source","DELETE FROM poc.items WHERE id=2; BEGIN; INSERT INTO poc.items VALUES(4,'rolled-back',4); ROLLBACK; UPDATE poc.items SET value='final-three' WHERE id=3")
            let end = try h.boundary("source")
            report["end"] = end.json; report["rotation"] = [beforeRotation.json,afterRotation.json]
            let positive = try finishClient(p,"position",success:true), auto = try finishClient(g,"gtid",success:true)
            try require(positive.0 == auto.0,"GTID and positional transaction JSON differ")
            let groups = try positive.0.split(separator:10).map { try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any] }
            try require(groups.count == 4,"incorrect complete transaction count")
            var operations: [RowOperation] = []
            var identities: [String] = []
            for group in groups {
                guard let identity = group["gtid"] as? [String:Any], let sid = identity["sid"] as? String, let sequence = identity["sequence"] as? String else { throw LabError("missing GTID") }
                identities.append(sid + ":" + sequence)
                for event in group["events"] as? [[String:Any]] ?? [] {
                    for row in event["rows"] as? [[String:Any]] ?? [] {
                        func values(_ key: String) throws -> [String]? {
                            guard let values = row[key] as? [[String:Any]] else { return nil }
                            return try values.map { value in
                                guard let kind = value["kind"] as? String,["signed","unsigned","utf8"].contains(kind),let exact = value["value"] as? String else { throw LabError("unexpected row value") }
                                return exact
                            }
                        }
                        operations.append(RowOperation(row["operation"] as? String ?? "",before:try values("before"),after:try values("after")))
                    }
                }
            }
            try Comparison.operations(operations,expected:Fixture.operations)
            let delta = try h.sql("source","SELECT GTID_SUBTRACT('\(end.gtids)','\(start.gtids)')")
            let captured = identities.joined(separator:",")
            try require(h.sql("source","SELECT GTID_SUBSET('\(delta)','\(captured)') AND GTID_SUBSET('\(captured)','\(delta)')") == "1","captured GTIDs differ from source delta")
            for diagnostic in [positive.1,auto.1] {
                let boundary = diagnostic["lastCompleteBoundary"] as? [String:String]
                try require(boundary?["file"] == end.file && boundary?["position"] == String(end.position),"final capture position differs")
                try require(diagnostic["transactions"] as? Int == 4 && diagnostic["durableProgress"] as? Bool == false,"incorrect capture summary")
                try require((diagnostic["rotationAnnouncements"] as? Int ?? 0) >= 2,"rotation was not followed")
            }
            let waited = try h.sql("native","SELECT SOURCE_POS_WAIT('\(end.file)',\(end.position),30)")
            let status = try h.status()
            try require(waited != "NULL" && waited != "-1" && status["Last_SQL_Errno"] == "0" && status["Last_IO_Errno"] == "0","native did not converge")
            try require(h.rows("source") == Fixture.final && h.rows("native") == Fixture.final && h.rows("target57") == Fixture.seed,"final rows differ")
            _ = try h.sql("native","STOP REPLICA")
            let nativeEnd = try h.boundary("native")
            try Comparison.operations(h.capture("native",start:nativeStart,end:nativeEnd),expected:Fixture.operations)
            _ = try h.capture("source",start:nil,end:nil)
            var reference: [RowOperation] = []
            for window in [(start,beforeRotation),(afterRotation,end)] {
                let file = output.appendingPathComponent("source/" + window.0.file)
                let decoded = try record("reference-" + window.0.file,[h.decoder,"--no-defaults","--verify-binlog-checksum","--base64-output=DECODE-ROWS","-vv",file.path])
                reference += try BinlogReference.parse(decoded.text,from:window.0.position,before:window.1.position)
            }
            try Comparison.operations(reference,expected:operations)
            var replay = gtid; replay["nonBlocking"] = true
            let r = try startClient("replay",replay)
            try require(finishClient(r,"replay",success:true).0 == positive.0,"explicit GTID replay differs")
            var resumed = configuration("gtid",9004,at:beforeRotation)
            resumed["nonBlocking"] = true; resumed["stopAfterTransactions"] = 2
            let resume = try startClient("resume",resumed)
            let suffix = Data(positive.0.split(separator:10).suffix(2).flatMap { Array($0) + [UInt8(10)] })
            try require(finishClient(resume,"resume",success:true).0 == suffix,"GTID resume after completed groups differs")
            var empty = configuration("gtid",9005,at:try h.boundary("source"))
            empty["nonBlocking"] = true; empty.removeValue(forKey:"stopAfterTransactions")
            let eof = try startClient("eof",empty)
            let exhausted = try finishClient(eof,"eof",success:true)
            try require(exhausted.0.isEmpty && exhausted.1["transactions"] as? Int == 0,"empty nonblocking dump did not finish cleanly")
            // A real socket disconnect while idle must fail without inventing a
            // completed transaction. Mid-group cuts use deterministic wire tests.
            let current = try h.boundary("source")
            var idle = configuration("file-position",9003,at:current); idle.removeValue(forKey:"stopAfterTransactions")
            let i = try startClient("disconnect",idle)
            let ids = try waitForReaders(1)
            _ = try h.sql("source","KILL CONNECTION \(ids[0])")
            let disconnected = try finishClient(i,"disconnect",success:false)
            let progress = disconnected.1["progress"] as? [String:Any]
            try require(disconnected.0.isEmpty && progress?["transactions"] as? Int == 0 && progress?["completeGTIDSet"] as? String == current.gtids,"idle disconnect advanced transactions/GTIDs")
            for label in ["hostname","untrusted","identity"] {
                var bad = configuration("file-position",9010,at:current)
                if label == "hostname" { bad["serverHostname"] = "wrong.example" }
                if label == "untrusted" { bad.removeValue(forKey:"caFile") }
                if label == "identity" { bad["sourceUUID"] = "00000000-0000-0000-0000-000000000001" }
                let c = try startClient(label,bad)
                try require(finishClient(c,label,success:false).0.isEmpty,"\(label) emitted transactions")
            }
            _ = try h.sql("source","PURGE BINARY LOGS TO '\(current.file)'")
            let purged = try startClient("purged",replay)
            let rejected = try finishClient(purged,"purged",success:false)
            try require(rejected.0.isEmpty && String(describing:rejected.1).contains("1236"),"purged history did not stop with source error 1236")
            report["checks"] = ["verified_tls", "positional_and_gtid_identical", "exact_source_gtids", "rotation", "exact_row_values", "mysqlbinlog_reference", "native_myisam_convergence", "explicit_gtid_replay", "gtid_resume", "nonblocking_eof", "disconnect", "wrong_hostname", "untrusted_ca", "source_identity", "purged_history"]
        } catch { failure = error; report["error"] = String(describing:error) }
        var cleanup: [String] = []
        for client in clients {
            // Preserve even failed-client diagnostics before removing our fixtures.
            if let logs = try? docker(["logs",client]) { try? (logs.stdout + logs.stderr).write(to:output.appendingPathComponent(client + ".log")) }
            do { _ = try docker(["rm","-f",client]) } catch { cleanup.append(String(describing:error)) }
        }
        if started {
            if let logs = try? h.compose(["logs","--no-color"]) { try? (logs.stdout + logs.stderr).write(to:output.appendingPathComponent("containers.log")) }
            do { _ = try h.compose(["down","--volumes","--remove-orphans"]) } catch { cleanup.append(String(describing:error)) }
        }
        report["cleanup"] = cleanup.isEmpty ? "passed" : cleanup.joined(separator:"\n")
        if !cleanup.isEmpty && failure == nil { failure = LabError("live fixture cleanup failed") }
        report["result"] = failure == nil ? "passed" : "failed"
        try writeJSON(report,to:output.appendingPathComponent("result.json"))
        if let failure { throw LabError("\(failure); evidence: \(output.path)") }
        print("PASS: live capture, native reference and failures; Swift apply and durable storage pending.")
    }
}
