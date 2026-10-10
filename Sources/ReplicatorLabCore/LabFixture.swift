import Foundation

/// Shared disposable topology. Physical service names are resolved at this boundary.
final class LabFixture {
    let profile: LabProfile
    let variant: LabVariant
    let codeCoverage: Bool
    let h: NativeHarness
    var image: String
    var config: [String:Any] = [:]
    var bootstrap: [String:Any] = [:]
    var versions: [String:Any] = [:]
    var clients: [String] = []
    var coverageInvocations: [[String:Any]] = []
    var output: URL { h.output }
    var runner: ProcessRunner { h.runner }
    var volume: String { h.project + "-evidence" }
    var helper: String { h.project + "-copy" }
    init(root: URL, category: String = "reverse-suite", identifier: String = runID(), image: String = "mysql-replicator-packaging:reverse", profile: LabProfile = .reverse, codeCoverage: Bool = false, variant: LabVariant = .standard) {
        self.profile=profile; self.codeCoverage=codeCoverage; self.variant=variant
        var nativeCase=NativeCase(); nativeCase.autoPosition=variant.mode == "gtid"; nativeCase.nativeEngine=profile.targetEngine; nativeCase.transaction=profile.transactionalTarget
        h=NativeHarness(root:root,config:nativeCase,artifactCategory:category,identifier:identifier)
        self.image=image
        h.composeOverlays=[root.appendingPathComponent(profile.composeOverlay).path]
        h.serverVersions=Dictionary(uniqueKeysWithValues:LabProfile.Role.allCases.map { (profile.service($0),$0 == .target ? profile.targetVersion : profile.sourceVersion) })
        h.composeEnvironment=[profile.evidenceVariable:volume]
    }
    func stage(_ message: String) { FileHandle.standardError.write(Data((profile.rawValue + ": " + message + "\n").utf8)) }
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

        stage("starting source, native reference and target: " + profile.rawValue)
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
        for role in LabProfile.Role.allCases {
            if !profile.transactionalTarget {
                _ = try sql(role,"SET GLOBAL default_storage_engine=\(profile.engine(role)); SET GLOBAL default_tmp_storage_engine=\(profile.engine(role))")
            }
            _ = try sql(role,"SET GLOBAL collation_server=utf8mb4_bin")
            _ = try sql(role,seed.replacingOccurrences(of:"ENGINE=InnoDB",with:"ENGINE="+profile.engine(role)))
        }
        if profile.hasOptionalMetadata { _ = try sql(.source,"SET PERSIST binlog_row_metadata="+variant.metadata) }
        _ = try sql(.source,"CREATE USER 'capture_fixture'@'%' IDENTIFIED BY 'fixture-capture-only' REQUIRE SSL; GRANT REPLICATION SLAVE,REPLICATION CLIENT ON *.* TO 'capture_fixture'@'%'")
        _ = try sql(.target,"CREATE USER 'apply_fixture'@'%' IDENTIFIED BY 'fixture-apply-only' REQUIRE SSL; GRANT ALL PRIVILEGES ON *.* TO 'apply_fixture'@'%'" + (profile.targetVersion == .mysql84 ? "; GRANT SET_ANY_DEFINER ON *.* TO 'apply_fixture'@'%'" : ""))
        let baseline = try boundary(), uuid = try sql(.source,"SELECT @@server_uuid")
        // Reset only the disposable reference's locally generated seed GTIDs.
        let native=profile.nativeVersion
        let caFile: String
        if native == .mysql57 { caFile="/evidence/tls/ca.pem" }
        else {
            caFile="/tmp/lab-ca.pem"
            let nativeID=try h.compose(["ps","-q","native"]).text
            _ = try docker(["cp",tls.appendingPathComponent("ca.pem").path,nativeID+":"+caFile])
        }
        _ = try sql(.native,native.resetBinlogs+"; SET GLOBAL gtid_purged='\(baseline.gtids)'; "+native.connect(host:profile.service(.source),caFile:caFile,boundary:baseline,autoPosition:variant.mode == "gtid")+"; "+native.startReplica)
        versions["native_version"] = try h.sql("native","SELECT VERSION()")
        bootstrap = baseline.json
        versions["source_version"] = try sql(.source,"SELECT VERSION()")
        versions["target_version"] = try sql(.target,"SELECT VERSION()")
        config = ["applierProfiling":true,"version":2,"profile":profile.rawValue,"stateDirectory":"/evidence/state",
            "source":["version":2,"host":profile.service(.source),"port":3306,"username":"capture_fixture","passwordEnvironment":"SOURCE_PASSWORD","serverHostname":profile.service(.source),"caFile":"/evidence/tls/ca.pem","serverID":9101,"sourceUUID":uuid,"mode":variant.mode,"start":variant.start(baseline),"stopAfterTransactions":2],
            "target":["host":profile.service(.target),"port":3306,"username":"apply_fixture","passwordEnvironment":"TARGET_PASSWORD","serverHostname":profile.service(.target),"caFile":"/evidence/tls/ca.pem","nativeAutoStartDisabled":true],
            "batch":["maximumTransactions":8],"storage":["minimumFreeDiskBytes":16*1024*1024]]
    }
    func sql(_ role: LabProfile.Role, _ statement: String, preserveWhitespace: Bool = false) throws -> String {
        try h.sql(profile.service(role),statement,preserveWhitespace:preserveWhitespace)
    }
    func boundary(_ role: LabProfile.Role = .source) throws -> Boundary {
        try h.boundary(profile.service(role),statusCommand:profile.version(role) == "5.7" ? "SHOW MASTER STATUS" : "SHOW BINARY LOG STATUS")
    }
    func awaitNative() throws {
        let end = try boundary()
        let waited = try h.sql("native","SELECT WAIT_FOR_EXECUTED_GTID_SET('\(end.gtids)',90)")
        try h.sql("native",profile.nativeVersion.replicaStatus+"\\G",headers:true).write(to:output.appendingPathComponent("native-status.txt"),atomically:true,encoding:.utf8)
        try require(waited == "0","native reference failed to catch up; inspect native-status.txt")
    }

    func installConfig(_ name: String = "apply") throws {
        let file=output.appendingPathComponent(name+".yaml")
        try writeYAML(config,to:file)
        _ = try docker(["cp",file.path,helper+":/evidence/"+name+".yaml"])
    }
    func startClient(_ name: String, arguments: [String]) throws -> String {
        let client=h.project+"-"+name; clients.append(client)
        _ = try docker(["run","-d","--name",client,"--platform","linux/amd64","--network",h.project+"_fixture","--mount","type=volume,src=\(volume),dst=/evidence","-e","SOURCE_PASSWORD=fixture-capture-only","-e","TARGET_PASSWORD=fixture-apply-only","--entrypoint","/usr/local/bin/mysql-replicator"]+CodeCoverage.environment(enabled:codeCoverage,label:name)+[image]+arguments)
        if codeCoverage { coverageInvocations.append(["label":name,"exit_code":0]) }
        return client
    }
    func collectCoverage(allowEmpty: Bool = false) throws {
        guard codeCoverage else { return }
        for index in coverageInvocations.indices {
            guard let label=coverageInvocations[index]["label"] as? String else { continue }
            let client=h.project+"-"+label
            if clients.contains(client) {
                let status=try docker(["inspect",client,"--format","{{.State.Running}} {{.State.ExitCode}}"] ).text
                let fields=status.split(separator:" ")
                try require(fields.count == 2 && fields[0] == "false","coverage writer is still running: "+client)
                guard let code=Int(fields[1]) else { throw LabError("invalid coverage writer exit code") }
                coverageInvocations[index]["exit_code"]=code
            }
        }
        let file=output.appendingPathComponent("code-coverage-invocations.json")
        try writeJSON(coverageInvocations,to:file)
        _ = try docker(["cp",file.path,helper+":/evidence/code-coverage-invocations.json"])
        try CodeCoverage.collect(runner,image:image,volume:volume,label:h.project,allowEmpty:allowEmpty)
        _ = try docker(["cp",helper+":/evidence/code-coverage",output.path])
    }
    func recordRuntime() throws {
        var servers: [[String:Any]]=[]
        for role in LabProfile.Role.allCases {
            let id=try h.compose(["ps","-q",profile.service(role)]).text
            let image=try docker(["inspect",id,"--format","{{.Image}}"] ).text
            let settings=try sql(role,"SHOW VARIABLES WHERE Variable_name IN ('gtid_mode','enforce_gtid_consistency','binlog_format','binlog_row_image','binlog_row_metadata','default_storage_engine','sql_mode','character_set_server','collation_server','sync_binlog','innodb_flush_log_at_trx_commit','log_slave_updates','log_replica_updates','slave_parallel_workers','replica_parallel_workers')")
            let version=try sql(role,"SELECT VERSION()")
            try require(version.hasPrefix(profile.version(role)+"."),"unexpected server version for "+role.rawValue+": "+version)
            if role == .source {
                let expected=try sql(role,"SELECT @@gtid_mode,@@enforce_gtid_consistency,@@binlog_format,@@binlog_row_image")
                try require(expected == "ON\tON\tROW\tFULL","source replication settings differ: "+expected)
            }
            servers.append(["role":role.rawValue,"image":image,"settings":settings,"version":version])
        }
        let binary=try docker(["run","--rm","--entrypoint","sha256sum",image,"/usr/local/bin/mysql-replicator"]).text
        try writeJSON(["profile":profile.rawValue,"variant":variant.fields,"servers":servers,"runtime_image":image,"binary_sha256":String(binary.prefix(64)),"code_coverage":codeCoverage],to:output.appendingPathComponent("runtime.json"))
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
        let rows=try sql(.source,Self.comparison)
        // Normalize display-width differences (INT(11) vs INT) across versions.
        let schemaSQL="SELECT TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,DATA_TYPE,IS_NULLABLE,IFNULL(CHARACTER_MAXIMUM_LENGTH,0),IFNULL(COLLATION_NAME,''),COLUMN_KEY FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='reverse_poc' ORDER BY TABLE_NAME,ORDINAL_POSITION"
        let schema=try sql(.source,schemaSQL)
        for destination: LabProfile.Role in [.target,.native] {
            try require(try sql(destination,Self.comparison) == rows,"data mismatch: " + destination.rawValue)
            try require(try sql(destination,schemaSQL) == schema,"schema mismatch: " + destination.rawValue)
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
