import Foundation

/// Container userland qualification. Docker Desktop's kernel and emulation are
/// deliberately recorded; passing this is not old-kernel/fleet qualification.
public enum UbuntuQualification {
    public static func run(root: URL, build: Bool = true) throws {
        let runner = ProcessRunner(root: root)
        let id = "replicator-ubuntu-" + runID().lowercased()
        let output = root.appendingPathComponent("artifacts/ubuntu/" + id)
        let tls = output.appendingPathComponent("tls")
        try FileManager.default.createDirectory(at: tls, withIntermediateDirectories: true)
        let image = "mysql-replicator-packaging:ubuntu16.04"
        let mysql = id + "-mysql", writer = id + "-writer", smoke = id + "-smoke", recovery = id + "-recover"
        let volume = id + "-data"
        var containers: [String] = [], networkCreated = false, volumeCreated = false
        var report: [String: Any] = ["schema_version": 1, "result": "failed", "target": "Ubuntu 16.04 x86_64",
            "qualification": "container_userland_only", "fleet_kernel": "not_tested", "production_replication": "not_implemented"]
        var failure: Error?
        func record(_ name: String, _ args: [String], timeout: TimeInterval = 120, checked: Bool = true) throws -> CommandResult {
            let result = try runner.run(args, timeout: timeout, checked: false)
            try (result.stdout + result.stderr).write(to: output.appendingPathComponent(name + ".log"))
            try require(!checked || result.status == 0, "\(name) failed with exit \(result.status); see \(output.path)/\(name).log")
            return result
        }
        func docker(_ args: [String], checked: Bool = true) throws -> CommandResult {
            try runner.run(["docker"] + args, checked: checked)
        }
        print("Ubuntu packaging evidence: \(output.path)")
        do {
            let info = try record("docker-info", ["docker", "info", "--format", "{{json .}}"])
            let decoded = try JSONSerialization.jsonObject(with: info.stdout) as? [String: Any] ?? [:]
            report["docker_kernel"] = decoded["KernelVersion"]
            report["docker_architecture"] = decoded["Architecture"]
            report["amd64_emulated"] = ["aarch64", "arm64"].contains(decoded["Architecture"] as? String ?? "")
            if build {
                print("Building pinned static dependency probe (first build downloads toolchains).")
                _ = try record("build", ["docker", "build", "--platform", "linux/amd64", "--target", "runtime", "-f", "docker/packaging/Dockerfile", "-t", image, "."], timeout: 3600)
            }
            report["runtime_image"] = try docker(["image", "inspect", image, "--format", "{{.Id}}"]).text
            let environment = try record("runtime-environment", ["docker", "run", "--rm", "--platform", "linux/amd64", "--entrypoint", "/bin/sh", image, "-c", "cat /etc/os-release; uname -a; getconf GNU_LIBC_VERSION; cat /opt/packaging-evidence/elf.txt; cat /opt/packaging-evidence/toolchains.txt; cat /opt/packaging-evidence/sha256.txt; /usr/local/bin/mysql-replicator --version"])
            try require(environment.text.contains("VERSION_ID=\"16.04\"") && environment.text.contains("statically linked"), "wrong runtime environment or nonstatic artifact")
            // Generated credentials are local fixture material, never production secrets.
            _ = try record("ca", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "2", "-subj", "/CN=Replicator Packaging Test CA", "-keyout", tls.appendingPathComponent("ca-key.pem").path, "-out", tls.appendingPathComponent("ca.pem").path])
            _ = try record("server-csr", ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=packaging-mysql", "-keyout", tls.appendingPathComponent("server-key.pem").path, "-out", tls.appendingPathComponent("server.csr").path])
            let ext = tls.appendingPathComponent("extensions.cnf")
            try "subjectAltName=DNS:packaging-mysql\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".write(to: ext, atomically: true, encoding: .utf8)
            _ = try record("server-cert", ["openssl", "x509", "-req", "-in", tls.appendingPathComponent("server.csr").path, "-CA", tls.appendingPathComponent("ca.pem").path, "-CAkey", tls.appendingPathComponent("ca-key.pem").path, "-CAcreateserial", "-days", "2", "-sha256", "-extfile", ext.path, "-out", tls.appendingPathComponent("server.pem").path])
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tls.appendingPathComponent("server-key.pem").path)
            _ = try docker(["network", "create", "--internal", id]); networkCreated = true
            _ = try docker(["volume", "create", volume]); volumeCreated = true
            containers.append(mysql)
            _ = try record("mysql-start", ["docker", "run", "-d", "--name", mysql, "--network", id, "--network-alias", "packaging-mysql",
                "--mount", "type=bind,src=\(tls.path),dst=/tls,readonly", "-e", "MYSQL_ROOT_PASSWORD=packaging-root-only", "-e", "MYSQL_DATABASE=probe", "-e", "MYSQL_USER=probe", "-e", "MYSQL_PASSWORD=packaging-only",
                "mysql:8.4.8-oracle@sha256:2952e3be7807f06fc18de50b3ea1a632d5c70d63482ff7d7376fe3aa8999babf",
                "--ssl-ca=/tls/ca.pem", "--ssl-cert=/tls/server.pem", "--ssl-key=/tls/server-key.pem", "--require-secure-transport=ON"])
            var ready = false
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                let check = try docker(["exec", "-e", "MYSQL_PWD=packaging-root-only", mysql, "mysql", "--no-defaults", "-uroot", "-h127.0.0.1", "-e", "SELECT 1"], checked: false)
                if check.status == 0 { ready = true; break }
                Thread.sleep(forTimeInterval: 1)
            }
            try require(ready, "MySQL fixture did not become ready")
            containers.append(smoke)
            _ = try record("smoke", ["docker", "run", "--name", smoke, "--platform", "linux/amd64", "--network", id,
                "--mount", "type=bind,src=\(tls.appendingPathComponent("ca.pem").path),dst=/fixture-ca.pem,readonly", image, "smoke", "packaging-mysql", "/fixture-ca.pem"], timeout: 90)
            containers.append(writer)
            _ = try docker(["run", "-d", "--name", writer, "--platform", "linux/amd64", "--network", "none", "--mount", "type=volume,src=\(volume),dst=/data", image, "crash-writer", "/data/relay.db"])
            var writerReady = false
            let writeDeadline = Date().addingTimeInterval(30)
            while Date() < writeDeadline {
                if try docker(["logs", writer]).text.contains("ready_for_kill") { writerReady = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            try require(writerReady, "SQLite writer did not reach durable/uncommitted boundary")
            _ = try record("writer-kill", ["docker", "kill", "--signal", "KILL", writer])
            try require(docker(["inspect", writer, "--format", "{{.State.ExitCode}} {{.State.OOMKilled}}"]).text == "137 false", "writer termination was not deliberate SIGKILL")
            containers.append(recovery)
            _ = try record("recovery", ["docker", "run", "--name", recovery, "--platform", "linux/amd64", "--network", "none", "--mount", "type=volume,src=\(volume),dst=/data", image, "recover", "/data/relay.db"])
            _ = try record("restart", ["docker", "start", "-a", recovery])
            try require(docker(["inspect", recovery, "--format", "{{.State.ExitCode}}"]).text == "0", "recovery restart failed")
            _ = try docker(["cp", "\(recovery):/opt/packaging-evidence", output.appendingPathComponent("build-evidence").path])
            _ = try docker(["cp", "\(recovery):/usr/local/bin/packaging-probe", output.appendingPathComponent("packaging-probe").path])
            _ = try docker(["cp", "\(recovery):/usr/local/bin/mysql-replicator", output.appendingPathComponent("mysql-replicator").path])
            report["checks"] = ["static_elf", "rust_codec", "zstd", "dns", "nio_timer", "mysql_verified_tls", "wrong_hostname_rejected", "untrusted_ca_rejected", "sqlite_sigkill_recovery", "sqlite_writer_lock", "sqlite_checkpoint", "process_restart"]
        } catch { failure = error; report["error"] = String(describing: error) }
        var cleanupErrors: [String] = []
        for name in containers.reversed() {
            _ = try? record(name + "-container", ["docker", "logs", name], checked: false)
            do {
                // -v also removes MySQL's anonymous datadir volume from this run.
                let removed = try docker(["rm", "-f", "-v", name], checked: false)
                if removed.status != 0 { cleanupErrors.append(removed.text + String(decoding: removed.stderr, as: UTF8.self)) }
            } catch { cleanupErrors.append(String(describing: error)) }
        }
        if volumeCreated { do { _ = try docker(["volume", "rm", volume]) } catch { cleanupErrors.append(String(describing: error)) } }
        if networkCreated { do { _ = try docker(["network", "rm", id]) } catch { cleanupErrors.append(String(describing: error)) } }
        report["cleanup"] = cleanupErrors.isEmpty ? "passed" : cleanupErrors.joined(separator: "\n")
        if !cleanupErrors.isEmpty && failure == nil { failure = LabError("packaging cleanup failed") }
        report["result"] = failure == nil ? "passed" : "failed"
        try writeJSON(report, to: output.appendingPathComponent("result.json"))
        if let failure { throw failure }
        print("PASS: Ubuntu 16.04 container userland; fleet kernel qualification remains open. \(output.path)")
    }
}
