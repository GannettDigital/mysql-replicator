import XCTest
@testable import ReplicatorLabCore

final class ProcessRunnerTests: XCTestCase {
    func testLargeStdoutAndStderrDoNotDeadlock() throws {
        let runner = ProcessRunner(root: FileManager.default.temporaryDirectory)
        let result = try runner.run(["/bin/sh", "-c", "i=0; while [ $i -lt 10000 ]; do printf '012345678901234567890123456789\\n'; printf '012345678901234567890123456789\\n' >&2; i=$((i+1)); done"], timeout: 10)
        XCTAssertEqual(result.stdout.count, 310000)
        XCTAssertEqual(result.stderr.count, 310000)
    }
    func testTimeoutTerminatesCommand() {
        let runner = ProcessRunner(root: FileManager.default.temporaryDirectory)
        let start = Date()
        XCTAssertThrowsError(try runner.run(["/bin/sleep", "10"], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testNonzeroExitIsNotAValidResult() {
        let runner = ProcessRunner(root: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try runner.run(["/usr/bin/false"]))
    }
}
