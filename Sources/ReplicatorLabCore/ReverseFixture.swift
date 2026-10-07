import Foundation

/// One disposable topology shared by automated qualification and the reverse demo.
/// Compose's inherited names: target57 = source, source = target, native = reference.
final class ReverseFixture {
    let h: NativeHarness
    var image: String
    var config: [String:Any] = [:]
    var bootstrap: [String:Any] = [:]
    var versions: [String:Any] = [:]
    var clients: [String] = []
    var output: URL { h.output }
    var runner: ProcessRunner { h.runner }
    var volume: String { h.project + "-evidence" }
    var helper: String { h.project + "-copy" }
    init(root: URL, category: String = "reverse-suite", identifier: String = runID(), image: String = "mysql-replicator-packaging:reverse") {
        var nativeCase=NativeCase(); nativeCase.nativeEngine="InnoDB"
        h=NativeHarness(root:root,config:nativeCase,artifactCategory:category,identifier:identifier)
        self.image=image
        h.composeOverlays=[root.appendingPathComponent("docker/reverse/compose.yaml").path]
        h.composeEnvironment=["REPLICATOR_REVERSE_EVIDENCE_VOLUME":volume]
    }
    func stage(_ message: String) { FileHandle.standardError.write(Data(("Reverse: " + message + "\n").utf8)) }
    func docker(_ args: [String], checked: Bool = true) throws -> CommandResult { try runner.run(["docker"]+args,checked:checked) }
    func prepare(build: Bool) throws {
        let tls=output.appendingPathComponent("tls")
        try FileManager.default.createDirectory(at:tls,withIntermediateDirectories:true)
        stage("evidence: " + output.path)
        if build {
            let result=try runner.run(["docker","build","--platform","linux/amd64","--target","runtime","-f","docker/packaging/Dockerfile","-t",image,"."],timeout:1800,checked:false)
            try (result.stdout+result.stderr).write(to:output.appendingPathComponent("build.log"))
            try require(result.status == 0,"reverse image build failed; see build.log")
        }
        image=try runner.run(["docker","image","inspect",image,"--format","{{.Id}}"]).text
        _ = try runner.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-sha256","-days","7","-subj","/CN=Reverse Fixture CA","-keyout",tls.appendingPathComponent("ca-key.pem").path,"-out",tls.appendingPathComponent("ca.pem").path])
        _ = try runner.run(["openssl","req","-newkey","rsa:2048","-nodes","-sha256","-subj","/CN=source","-keyout",tls.appendingPathComponent("server-key.pem").path,"-out",tls.appendingPathComponent("server.csr").path])
        let ext = tls.appendingPathComponent("extensions.cnf")
        try "subjectAltName=DNS:source,DNS:target57\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".write(to:ext,atomically:true,encoding:.utf8)
        _ = try runner.run(["openssl","x509","-req","-in",tls.appendingPathComponent("server.csr").path,"-CA",tls.appendingPathComponent("ca.pem").path,"-CAkey",tls.appendingPathComponent("ca-key.pem").path,"-CAcreateserial","-days","7","-sha256","-extfile",ext.path,"-out",tls.appendingPathComponent("server.pem").path])
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:tls.appendingPathComponent("server-key.pem").path)
        _ = try docker(["volume","create",volume])
        _ = try docker(["create","--name",helper,"--platform","linux/amd64","--mount","type=volume,src=\(volume),dst=/evidence","--entrypoint","/bin/true",image])
        _ = try docker(["cp",tls.path,helper+":/evidence/tls"])

        stage("starting 5.7 source, native 5.7 reference and 8.4 target")
        _ = try h.compose(["up","-d","--build","--wait","--wait-timeout","300","target57","source","native"],timeout:360,onOutput:{ FileHandle.standardError.write($0) })
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
        for service in ["target57","source","native"] { _ = try h.sql(service,seed) }
        _ = try h.sql("target57","CREATE USER 'capture_fixture'@'%' IDENTIFIED BY 'fixture-capture-only' REQUIRE SSL; GRANT REPLICATION SLAVE,REPLICATION CLIENT ON *.* TO 'capture_fixture'@'%'")
        _ = try h.sql("source","CREATE USER 'apply_fixture'@'%' IDENTIFIED BY 'fixture-apply-only' REQUIRE SSL; GRANT ALL PRIVILEGES ON *.* TO 'apply_fixture'@'%'; GRANT SET_ANY_DEFINER ON *.* TO 'apply_fixture'@'%'")
        let baseline = try h.boundary("target57"), uuid = try h.sql("target57","SELECT @@server_uuid")
        // Reset only the disposable reference's locally generated seed GTIDs.
        _ = try h.sql("native","RESET MASTER; SET GLOBAL gtid_purged='\(baseline.gtids)'; CHANGE MASTER TO MASTER_HOST='target57',MASTER_USER='capture_fixture',MASTER_PASSWORD='fixture-capture-only',MASTER_SSL=1,MASTER_SSL_CA='/evidence/tls/ca.pem',MASTER_SSL_VERIFY_SERVER_CERT=1,MASTER_AUTO_POSITION=1; START SLAVE")
        versions["native_version"] = try h.sql("native","SELECT VERSION()")
        bootstrap = baseline.json
        versions["source_version"] = try h.sql("target57","SELECT VERSION()")
        versions["target_version"] = try h.sql("source","SELECT VERSION()")
        config = ["applierProfiling":true,"version":2,"profile":"mysql57-to-mysql84-innodb","stateDirectory":"/evidence/state",
            "source":["version":2,"host":"target57","port":3306,"username":"capture_fixture","passwordEnvironment":"SOURCE_PASSWORD","serverHostname":"target57","caFile":"/evidence/tls/ca.pem","serverID":9101,"sourceUUID":uuid,"mode":"gtid","start":["file":baseline.file,"position":baseline.position,"executedGTIDs":baseline.gtids],"stopAfterTransactions":2],
            "target":["host":"source","port":3306,"username":"apply_fixture","passwordEnvironment":"TARGET_PASSWORD","serverHostname":"source","caFile":"/evidence/tls/ca.pem","nativeAutoStartDisabled":true],
            "batch":["maximumTransactions":8],"storage":["minimumFreeDiskBytes":16*1024*1024]]
    }
    func awaitNative() throws {
        let end = try h.boundary("target57")
        let waited = try h.sql("native","SELECT WAIT_FOR_EXECUTED_GTID_SET('\(end.gtids)',90)")
        try h.sql("native","SHOW SLAVE STATUS\\G",headers:true).write(to:output.appendingPathComponent("native-status.txt"),atomically:true,encoding:.utf8)
        try require(waited == "0","native 5.7 reference failed to catch up; inspect native-status.txt")
    }

    func installConfig(_ name: String = "apply") throws {
        let file=output.appendingPathComponent(name+".yaml")
        try writeYAML(config,to:file)
        _ = try docker(["cp",file.path,helper+":/evidence/"+name+".yaml"])
    }
    func startClient(_ name: String, arguments: [String]) throws -> String {
        let client=h.project+"-"+name; clients.append(client)
        _ = try docker(["run","-d","--name",client,"--platform","linux/amd64","--network",h.project+"_fixture","--mount","type=volume,src=\(volume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only","--entrypoint","/usr/local/bin/mysql-replicator",image]+arguments)
        return client
    }
    func recovery(_ arguments: [String], label: String) throws -> [String:Any] {
        let result=try docker(["run","--rm","--platform","linux/amd64","--network","none","--mount","type=volume,src=\(volume),dst=/evidence","--entrypoint","/usr/local/bin/mysql-replicator",image,"recovery"]+arguments+["--config","/evidence/apply.yaml"])
        try result.stdout.write(to:output.appendingPathComponent(label+".json"))
        guard let value=try JSONSerialization.jsonObject(with:result.stdout) as? [String:Any] else { throw LabError("missing recovery report") }
        return value
    }
    func counters(_ service: String) throws -> [String:Int64] {
        let text=try h.sql(service,"SHOW GLOBAL STATUS WHERE Variable_name IN ('Handler_write','Handler_update','Handler_delete','Com_commit','Com_rollback','Com_stmt_execute','Com_stmt_prepare','Questions')")
        return try Dictionary(uniqueKeysWithValues:text.split(separator:"\n").map { line in
            let parts=line.split(separator:"\t")
            guard parts.count == 2, let value=Int64(parts[1]) else { throw LabError("invalid server counter") }
            return (String(parts[0]),value)
        })
    }
    static let comparison = "SELECT report_date,id,HEX(value),amount,choice+0,flags+0,HEX(payload) FROM reverse_poc.items ORDER BY report_date,id; SELECT * FROM reverse_poc.aux ORDER BY id"
    func compare() throws {
        try awaitNative()
        let rows=try h.sql("target57",Self.comparison)
        // Normalize display-width differences (INT(11) vs INT) across versions.
        let schemaSQL="SELECT TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,DATA_TYPE,IS_NULLABLE,IFNULL(CHARACTER_MAXIMUM_LENGTH,0),IFNULL(COLLATION_NAME,''),COLUMN_KEY FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='reverse_poc' ORDER BY TABLE_NAME,ORDINAL_POSITION"
        let schema=try h.sql("target57",schemaSQL)
        for destination in ["source","native"] {
            try require(try h.sql(destination,Self.comparison) == rows,"reverse data mismatch: " + destination)
            try require(try h.sql(destination,schemaSQL) == schema,"reverse schema mismatch: " + destination)
        }
    }
    func cleanup() throws {
        // Retained demo applier has a stable name; suite clients are tracked.
        for client in clients {
            if try docker(["inspect",client],checked:false).status == 0 { _ = try docker(["rm","-f",client]) }
        }
        _ = try h.compose(["down","-v","--remove-orphans"])
        if try docker(["inspect",helper],checked:false).status == 0 { _ = try docker(["rm","-f",helper]) }
        if try docker(["volume","inspect",volume],checked:false).status == 0 { _ = try docker(["volume","rm",volume]) }
    }
}
