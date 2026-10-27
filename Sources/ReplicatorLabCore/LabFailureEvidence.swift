import Foundation

/// Keep the test failure even when diagnostic collection also fails.
enum LabFailureEvidence {
    static func command(image: String, volume: String) -> [String] {
        [
            "run", "--rm", "--platform", "linux/amd64", "--network", "none",
            "--mount", "type=volume,src=\(volume),dst=/evidence",
            "--entrypoint", "/usr/local/bin/mysql-replicator", image,
            "support-bundle", "--config", "/evidence/failure-support.yaml",
        ]
    }

    static func collect(
        failure: String, output: URL, cases: [[String: Any]],
        capture: ([String: Any]) throws -> URL, log: (String) -> Void
    ) -> [String: Any] {
        var record: [String: Any] = ["error": failure, "cases": cases, "artifacts": output.path]
        do {
            let bundle = try capture(record)
            record["supportBundle"] = ["status": "created", "output": bundle.path]
            log("Support bundle: " + bundle.path)
        } catch {
            record["supportBundle"] = ["status": "failed", "reason": String(describing: error)]
            log("Support bundle collection failed: \(error)")
        }
        do { try writeJSON(record, to: output.appendingPathComponent("harness-failure.json")) } catch {
            log("Could not save harness failure: \(error)")
        }
        log("Failure details: " + output.appendingPathComponent("harness-failure.json").path)
        return record
    }
}

extension LabFixture {
    func captureFailure(_ error: Error, cases: [[String: Any]], applier: LabApplier) -> [String: Any] {
        LabFailureEvidence.collect(
            failure: String(describing: error), output: output, cases: cases,
            capture: { record in
                // The support command requires a stopped writer. Never remove a live
                // lock or replace the original test error with a collection error.
                try applier.drain()
                try applier.archiveLogs()
                let failure = output.appendingPathComponent("harness-failure.json")
                try writeJSON(record, to: failure)
                _ = try docker(["cp", failure.path, helper + ":/evidence/harness-failure.json"])
                let name = "harness-" + runID()
                let remote = "/evidence/support-bundles/" + name
                var request = config
                request["supportBundle"] = [
                    "output": remote, "format": "directory",
                    "logs": ["/evidence/harness-failure.json", "/evidence/applier.ndjson", "/evidence/applier.stderr"],
                ]
                let configFile = output.appendingPathComponent("failure-support.yaml")
                try writeYAML(request, to: configFile)
                _ = try docker(["cp", configFile.path, helper + ":/evidence/failure-support.yaml"])
                // The file-copy helper is a stopped container. Use a separate,
                // network-disabled process to read the stopped writer's volume.
                let command = try docker(LabFailureEvidence.command(image: image, volume: volume), checked: false)
                try (command.stdout + command.stderr).write(to: output.appendingPathComponent("failure-support.log"))
                try require(
                    command.status == 0,
                    "support-bundle exited \(command.status): " + String(decoding: command.stderr, as: UTF8.self))
                let directory = output.appendingPathComponent("support-bundles")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                _ = try docker(["cp", helper + ":" + remote, directory.path])
                let local = directory.appendingPathComponent(name)
                for file in ["bundle.json", "state.sqlite", "diagnostics.json"] {
                    try require(
                        FileManager.default.fileExists(atPath: local.appendingPathComponent(file).path),
                        "support bundle lacks " + file)
                }
                return local
            }, log: stage)
    }
}
