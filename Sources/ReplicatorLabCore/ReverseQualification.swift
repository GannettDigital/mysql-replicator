import Foundation

/// Independent initial profile qualification. The service names are inherited
/// from NativeHarness: target57 is our source; source is our 8.4 destination.
public enum ReverseQualification {
    public static func run(root: URL, build: Bool) throws {
        let h = NativeHarness(root:root,config:.init(),artifactCategory:"reverse-suite")
        let runner = h.runner, output = h.output, tls = output.appendingPathComponent("tls")
        let image = "mysql-replicator-packaging:reverse"
        try FileManager.default.createDirectory(at:tls,withIntermediateDirectories:true)
        func stage(_ message: String) { FileHandle.standardError.write(Data(("Reverse: " + message + "\n").utf8)) }
        stage("evidence: " + output.path)
        if build {
            let result = try runner.run(["docker","build","--platform","linux/amd64","--target","runtime","-f","docker/packaging/Dockerfile","-t",image,"."],timeout:1800,checked:false)
            try (result.stdout+result.stderr).write(to:output.appendingPathComponent("build.log"))
            try require(result.status == 0,"reverse image build failed; see build.log")
        }
        let qualifiedImage = try runner.run(["docker","image","inspect",image,"--format","{{.Id}}"]).text
        func docker(_ args: [String], checked: Bool = true) throws -> CommandResult {
            try runner.run(["docker"]+args,checked:checked)
        }
        let volume = h.project + "-evidence", helper = h.project + "-copy"
        h.composeOverlays = [root.appendingPathComponent("docker/reverse/compose.yaml").path]
        h.composeEnvironment = ["REPLICATOR_REVERSE_EVIDENCE_VOLUME":volume]
        var clients: [String] = [], started = false, createdVolume = false, createdHelper = false
        var report: [String:Any] = ["profile":"mysql57-to-mysql84-innodb","result":"failed","image":qualifiedImage]
        defer {
            for client in clients { _ = try? docker(["rm","-f",client],checked:false) }
            if started { _ = try? h.compose(["down","-v","--remove-orphans"],checked:false) }
            if createdHelper { _ = try? docker(["rm","-f",helper],checked:false) }
            if createdVolume { _ = try? docker(["volume","rm",volume],checked:false) }
        }
        do {
            _ = try runner.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-sha256","-days","2","-subj","/CN=Reverse Fixture CA","-keyout",tls.appendingPathComponent("ca-key.pem").path,"-out",tls.appendingPathComponent("ca.pem").path])
            _ = try runner.run(["openssl","req","-newkey","rsa:2048","-nodes","-sha256","-subj","/CN=source","-keyout",tls.appendingPathComponent("server-key.pem").path,"-out",tls.appendingPathComponent("server.csr").path])
            let ext = tls.appendingPathComponent("extensions.cnf")
            try "subjectAltName=DNS:source,DNS:target57\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".write(to:ext,atomically:true,encoding:.utf8)
            _ = try runner.run(["openssl","x509","-req","-in",tls.appendingPathComponent("server.csr").path,"-CA",tls.appendingPathComponent("ca.pem").path,"-CAkey",tls.appendingPathComponent("ca-key.pem").path,"-CAcreateserial","-days","2","-sha256","-extfile",ext.path,"-out",tls.appendingPathComponent("server.pem").path])
            try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:tls.appendingPathComponent("server-key.pem").path)
            _ = try docker(["volume","create",volume]); createdVolume = true
            _ = try docker(["create","--name",helper,"--platform","linux/amd64","--mount","type=volume,src=\(volume),dst=/evidence","--entrypoint","/bin/true",qualifiedImage]); createdHelper = true
            _ = try docker(["cp",tls.path,helper+":/evidence/tls"])
            started = true
            stage("starting 5.7 source and 8.4 target")
            _ = try h.compose(["up","-d","--build","--wait","--wait-timeout","300","target57","source"],timeout:360,onOutput:{ FileHandle.standardError.write($0) })
            let seed = """
                CREATE DATABASE reverse_poc CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
                CREATE TABLE reverse_poc.items (
                  report_date DATE NOT NULL, id BIGINT UNSIGNED NOT NULL,
                  value VARCHAR(100) NOT NULL, amount DECIMAL(12,2) NOT NULL,
                  choice ENUM('','ready','done') NOT NULL, flags SET('a','b') NOT NULL,
                  payload VARBINARY(32), PRIMARY KEY(report_date,id)
                ) ENGINE=InnoDB;
                CREATE TABLE reverse_poc.aux (id INT PRIMARY KEY, counter INT NOT NULL) ENGINE=InnoDB;
                INSERT INTO reverse_poc.items VALUES ('2026-10-06',1,'seed',1.00,'ready','a',X'00FF');
                """
            for service in ["target57","source"] { _ = try h.sql(service,seed) }
            _ = try h.sql("target57","CREATE USER 'capture_fixture'@'%' IDENTIFIED BY 'fixture-capture-only' REQUIRE SSL; GRANT REPLICATION SLAVE,REPLICATION CLIENT ON *.* TO 'capture_fixture'@'%'")
            _ = try h.sql("source","CREATE USER 'apply_fixture'@'%' IDENTIFIED BY 'fixture-apply-only' REQUIRE SSL; GRANT SELECT,INSERT,UPDATE,DELETE,TRIGGER,REPLICATION CLIENT ON *.* TO 'apply_fixture'@'%'")
            let baseline = try h.boundary("target57"), uuid = try h.sql("target57","SELECT @@server_uuid")
            report["baseline"] = baseline.json
            report["source_version"] = try h.sql("target57","SELECT VERSION()")
            report["target_version"] = try h.sql("source","SELECT VERSION()")
            var config: [String:Any] = ["version":2,"profile":"mysql57-to-mysql84-innodb","stateDirectory":"/evidence/state",
                "source":["version":2,"host":"target57","port":3306,"username":"capture_fixture","passwordEnvironment":"SOURCE_PASSWORD","serverHostname":"target57","caFile":"/evidence/tls/ca.pem","serverID":9101,"sourceUUID":uuid,"mode":"gtid","start":["file":baseline.file,"position":baseline.position,"executedGTIDs":baseline.gtids],"stopAfterTransactions":2],
                "target":["host":"source","port":3306,"username":"apply_fixture","passwordEnvironment":"TARGET_PASSWORD","serverHostname":"source","caFile":"/evidence/tls/ca.pem","nativeAutoStartDisabled":true],
                "batch":["maximumTransactions":8],"storage":["minimumFreeDiskBytes":16*1024*1024]]
            func run(_ label: String, initialize: Bool, success: Bool) throws -> [String:Any] {
                let path = output.appendingPathComponent(label+".yaml")
                try writeYAML(config,to:path); _ = try docker(["cp",path.path,helper+":/evidence/"+label+".yaml"])
                let client = h.project+"-"+label; clients.append(client)
                _ = try docker(["run","-d","--name",client,"--platform","linux/amd64","--network",h.project+"_fixture","--mount","type=volume,src=\(volume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only","--entrypoint","/usr/local/bin/mysql-replicator",qualifiedImage,"run","--config","/evidence/"+label+".yaml"] + (initialize ? ["--initialize"] : []))
                let exit = try runner.run(["docker","wait",client],timeout:90).text
                let logs = try docker(["logs",client])
                try logs.stdout.write(to:output.appendingPathComponent(label+".ndjson"))
                try logs.stderr.write(to:output.appendingPathComponent(label+".diagnostic.json"))
                try require(success ? exit == "0" : exit != "0","\(label) unexpected exit \(exit); inspect evidence")
                guard let line = logs.stderr.split(separator:10).last,
                      let summary = try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { throw LabError("missing reverse summary") }
                return summary
            }
            let positive = """
                START TRANSACTION;
                INSERT INTO reverse_poc.items VALUES
                  ('2026-10-06',2,'temporary',2.25,'ready','b',NULL),
                  ('2026-10-06',18446744073709551615,'héllo',3.50,'done','a,b',X'80FF');
                UPDATE reverse_poc.items SET value='intermediate' WHERE id=1;
                INSERT INTO reverse_poc.aux VALUES(1,10);
                UPDATE reverse_poc.items SET value='final',amount=7.75 WHERE id=1;
                DELETE FROM reverse_poc.items WHERE id=2;
                COMMIT;
                START TRANSACTION;
                UPDATE reverse_poc.items SET report_date='2026-10-07' WHERE id=18446744073709551615;
                INSERT INTO reverse_poc.aux VALUES(2,-20);
                COMMIT;
                """
            _ = try h.sql("target57",positive)
            report["positive"] = try run("positive",initialize:true,success:true)
            let comparison = "SELECT report_date,id,HEX(value),amount,choice+0,flags+0,HEX(payload) FROM reverse_poc.items ORDER BY report_date,id; SELECT * FROM reverse_poc.aux ORDER BY id"
            try require(try h.sql("target57",comparison) == h.sql("source",comparison),"reverse data mismatch")
            var source = config["source"] as! [String:Any]; source["stopAfterTransactions"] = 1; config["source"] = source
            _ = try h.sql("target57","START TRANSACTION; UPDATE reverse_poc.aux SET counter=11 WHERE id=1; UPDATE reverse_poc.items SET choice='ready' WHERE id=1; COMMIT")
            report["resume"] = try run("resume",initialize:false,success:true)
            try require(try h.sql("target57",comparison) == h.sql("source",comparison),"resumed data mismatch")
            // Diverge one key deliberately: source accepts both inserts, target
            // rejects the second. The first must roll back and stay unacknowledged.
            _ = try h.sql("source","INSERT INTO reverse_poc.aux VALUES(99,99)")
            _ = try h.sql("target57","START TRANSACTION; INSERT INTO reverse_poc.aux VALUES(3,30); INSERT INTO reverse_poc.aux VALUES(99,99); COMMIT")
            let failed = try run("rollback",initialize:false,success:false)
            report["rollback"] = failed
            let progress = failed["progress"] as? [String:Any], diagnostic = progress?["targetFailure"] as? [String:Any]
            try require(diagnostic?["transactionOutcome"] as? String == "rolledBack","missing confirmed rollback diagnostic")
            try require(progress?["transactionsApplied"] as? Int == 3,"failed transaction advanced checkpoint")
            try require(try h.sql("source","SELECT COUNT(*) FROM reverse_poc.aux WHERE id=3") == "0","partial transaction committed")
            _ = try docker(["cp",helper+":/evidence/state",output.path])
            let state = try runner.run(["sqlite3",output.appendingPathComponent("state/state.sqlite").path,"SELECT lifecycle,transactions_applied FROM state; SELECT DISTINCT status FROM row_intents WHERE gtid=(SELECT active_gtid FROM state)"]).text
            try require(state == "BLOCKED|3\nPENDING","rollback journal lost pending evidence")
            report["state"] = state; report["result"] = "passed"
            try writeJSON(report,to:output.appendingPathComponent("result.json"))
            stage("PASS: multi-table transactions, 5.7 metadata, composite PK changes, resume and rollback")
        } catch {
            report["error"] = String(describing:error)
            try? writeJSON(report,to:output.appendingPathComponent("result.json"))
            throw error
        }
    }
}
