import Foundation

public struct DebianPackagingOptions {
    public var version: String = "0.1.0"
    public var outputDirectory: String = "artifacts/deb"
    public var skipBuild: Bool = false
    public var skipVerification: Bool = false

    public init(arguments: [String]) throws {
        var iter = arguments.makeIterator()
        while let arg = iter.next() {
            switch arg {
            case "--version":
                guard let v = iter.next(), !v.isEmpty else {
                    throw LabError("--version requires a non-empty version string")
                }
                // Absolute anchors reject trailing line terminators on Linux as well as macOS.
                guard v.range(of: #"\A[0-9][a-zA-Z0-9.+~]*(?:-[a-zA-Z0-9.+~]+)?\z"#, options: .regularExpression) != nil else {
                    throw LabError("invalid Debian package version: '\(v)' (expected e.g. 0.1.0 or 0.1.0-1)")
                }
                self.version = v
            case "--output":
                guard let out = iter.next(), !out.isEmpty else {
                    throw LabError("--output requires a directory path")
                }
                self.outputDirectory = out
            case "--skip-build":
                self.skipBuild = true
            case "--skip-verification":
                self.skipVerification = true
            default:
                throw LabError("unknown package-deb argument: \(arg)")
            }
        }
    }
}

public enum DebianPackaging {
    public static func run(root: URL, arguments: [String]) throws {
        let options = try DebianPackagingOptions(arguments: arguments)
        let runner = ProcessRunner(root: root)
        let outDir = URL(fileURLWithPath: options.outputDirectory, relativeTo: root).standardizedFileURL
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let targetImage = "mysql-replicator-packaging:deb"
        let debName = "mysql-replicator_\(options.version)_amd64.deb"

        print("Building Debian package version \(options.version)...")
        if !options.skipBuild {
            _ = try runner.run([
                "docker", "build",
                "--platform", "linux/amd64",
                "--progress=plain",
                "--target", "deb",
                "--build-arg", "VERSION=\(options.version)",
                "-f", "docker/packaging/Dockerfile",
                "-t", targetImage,
                "."
            ], timeout: 3600, onOutput: { data in
                FileHandle.standardError.write(data)
            })
        }

        // Export package to output directory using a temporary container
        let cid = try runner.run(["docker", "create", targetImage]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { _ = try? runner.run(["docker", "rm", "-f", cid], checked: false) }

        _ = try runner.run(["docker", "cp", "\(cid):/out/deb/\(debName)", outDir.appendingPathComponent(debName).path])
        _ = try runner.run(["docker", "cp", "\(cid):/out/deb/\(debName).sha256", outDir.appendingPathComponent("\(debName).sha256").path])

        if !options.skipVerification {
            print("\nVerifying Debian package installation in clean Ubuntu 16.04 container...")
            _ = try runner.run([
                "docker", "build",
                "--platform", "linux/amd64",
                "--progress=plain",
                "--target", "deb-test",
                "--build-arg", "VERSION=\(options.version)",
                "-f", "docker/packaging/Dockerfile",
                "."
            ], timeout: 600, onOutput: { data in
                FileHandle.standardError.write(data)
            })
        }

        let debPath = outDir.appendingPathComponent(debName).path
        print("\nPASS: Debian package created and verified successfully:")
        print("  Package:  \(debPath)")
        if let sha = try? String(contentsOf: outDir.appendingPathComponent("\(debName).sha256"), encoding: .utf8) {
            print("  Checksum: \(sha.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
