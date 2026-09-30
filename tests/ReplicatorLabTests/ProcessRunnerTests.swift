import XCTest
@testable import ReplicatorLabCore

final class ProcessRunnerTests: XCTestCase {
    func testLargeStdoutAndStderrDoNotDeadlock() throws {
        let runner = ProcessRunner(root: FileManager.default.temporaryDirectory)
        var streamedBytes = 0
        let result = try runner.run(["/bin/sh", "-c", "i=0; while [ $i -lt 10000 ]; do printf '012345678901234567890123456789\\n'; printf '012345678901234567890123456789\\n' >&2; i=$((i+1)); done"], timeout: 10,onOutput:{ streamedBytes += $0.count })
        XCTAssertEqual(streamedBytes,620000)
        XCTAssertEqual(result.stdout.count, 310000)
        XCTAssertEqual(result.stderr.count, 310000)
    }
    func testTimeoutTerminatesCommand() {
        let runner = ProcessRunner(root: FileManager.default.temporaryDirectory)
        let start = Date()
        XCTAssertThrowsError(try runner.run(["/bin/sleep", "10"], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testOutputIsDeliveredBeforeChildExit() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:marker) }
        let runner = ProcessRunner(root:FileManager.default.temporaryDirectory)
        var observed = Data()
        let result = try runner.run(["/bin/sh","-c","printf ready; while [ ! -e \"$REPLICATOR_PROGRESS_MARKER\" ]; do sleep 0.05; done; printf done"],
            environment:["REPLICATOR_PROGRESS_MARKER":marker.path],timeout:5,onOutput:{ data in
                observed.append(data)
                if String(decoding:observed,as:UTF8.self).contains("ready") {
                    FileManager.default.createFile(atPath:marker.path,contents:Data())
                }
            })
        XCTAssertEqual(result.text,"readydone")
        XCTAssertEqual(observed,result.stdout)
    }
    func testNonzeroExitIsNotAValidResult() {
        let runner = ProcessRunner(root: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try runner.run(["/usr/bin/false"]))
    }
}
