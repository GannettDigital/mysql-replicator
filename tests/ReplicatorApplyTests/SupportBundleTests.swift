import XCTest
import Foundation
@testable import ReplicatorApply
import ReplicatorCapture
import ReplicatorConfiguration

final class SupportBundleTests:XCTestCase {
    func testBundleRequiresStoppedWriterAndPreservesDiagnosticStateWithoutSecrets() throws {
        #if os(Linux)
        let helper=ApplyTests(name:"fixtures",testClosure:{_ in})
        #else
        let helper=ApplyTests()
        #endif
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"),output=root.appendingPathComponent("support.tar")
        let log=root.appendingPathComponent("large.log")
        try Data(repeating:65,count:1024*1024).write(to:log)
        let yaml=root.appendingPathComponent("apply.yaml")
        try """
        stateDirectory: \(state.path)
        source:
          password: highly-secret
        target:
          passwordEnvironment: SECRET_VAR
          privateKey: never-export
        supportBundle:
          output: \(output.path)
          maximumBytes: 1048576
          logs:
            - \(log.path)
        """.write(to:yaml,atomically:true,encoding:.utf8)
        let c=try ConfigurationFile.load(SupportBundleConfiguration.self,from:yaml)
        let diagnostic=try ConfigurationFile.diagnosticJSON(from:yaml)
        let text=String(decoding:diagnostic,as:UTF8.self)
        XCTAssertFalse(text.contains("highly-secret"));XCTAssertFalse(text.contains("SECRET_VAR"));XCTAssertFalse(text.contains("never-export"))
        do {
            let store=try StateStore(configuration:helper.config(state.path))
            try store.block("customer row value to preserve")
            XCTAssertThrowsError(try SupportBundle.run(configuration:c,redactedConfiguration:diagnostic,version:"test")) {
                XCTAssertTrue(String(describing:$0).contains("active writer"))
            }
        }
        let db=state.appendingPathComponent("state.sqlite")
        let before=try ArchiveIO.hash(db)
        let result=try SupportBundle.run(configuration:c,redactedConfiguration:diagnostic,version:"test")
        XCTAssertTrue(result.containsCustomerData)
        XCTAssertGreaterThanOrEqual(result.files,5)
        XCTAssertTrue(result.omitted.contains { $0.contains("logs/0.log: size limit") })
        XCTAssertEqual(try ArchiveIO.hash(db),before)
        let attributes=try FileManager.default.attributesOfItem(atPath:output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let bytes=try Data(contentsOf:output)
        XCTAssertNotNil(bytes.range(of:Data("customer row value to preserve".utf8)))
        XCTAssertNil(bytes.range(of:Data("highly-secret".utf8)))
        XCTAssertThrowsError(try SupportBundle.run(configuration:c,redactedConfiguration:diagnostic,version:"test"))
        // Validate the archive using an independent reader, including SQLite.
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env")
        process.arguments=["tar","-xf",output.path,"-C",root.path,"state.sqlite"]
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        XCTAssertEqual(try helper.sqlite(root.appendingPathComponent("state.sqlite"),"SELECT lifecycle,diagnostic FROM state"),[["BLOCKED","customer row value to preserve"]])
    }
}
