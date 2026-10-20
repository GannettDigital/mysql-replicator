import Foundation
import Logging
import XCTest

@testable import ReplicatorLogging

final class ApplicationLogTests: XCTestCase {
    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [Data] = []
        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            records.append(data)
        }
        func snapshot() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return records
        }
    }
    func testDisabledLogsAreLazyAndLoggerCopiesKeepTheirLevels() {
        let buffer = Buffer()
        let sink = JSONLogSink(write: buffer.append)
        var logger = Logger(label: "test") { _ in JSONLogHandler(sink: sink) }
        var evaluated = 0
        func message() -> Logger.Message {
            evaluated += 1
            return "disabled"
        }
        func fields() -> Logger.Metadata {
            evaluated += 1
            return ["phase": "test"]
        }
        logger.debug(message(), metadata: fields())
        let value = ApplicationLog.measure("Disabled", level: .debug, metadata: fields(), logger: logger) { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(evaluated, 0)
        XCTAssertTrue(buffer.snapshot().isEmpty)
        let copy = logger
        logger.logLevel = .debug
        XCTAssertEqual(copy.logLevel, .warning)
    }
    func testRecordsAreJSONBoundedAndExcludeSensitiveMetadata() throws {
        let buffer = Buffer()
        let sink = JSONLogSink(write: buffer.append)
        sink.level = .debug
        let logger = Logger(label: "test") { _ in JSONLogHandler(sink: sink) }
        logger.info(
            "Read schema\nstarted",
            metadata: [
                "phase": "schema", "password": "secret", "sql": "SELECT secret", "binds": "private-value",
                "table": .string(String(repeating: "x", count: 10000)),
            ])
        let bytes = try XCTUnwrap(buffer.snapshot().first)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(record["kind"] as? String, "log")
        XCTAssertEqual(record["level"] as? String, "info")
        XCTAssertNotNil(record["timestamp"] as? Double)
        XCTAssertEqual(bytes.filter { $0 == 10 }.count, 1)
        let fields = try XCTUnwrap(record["fields"] as? [String: String])
        XCTAssertEqual(fields["phase"], "schema")
        XCTAssertEqual(fields["table"]?.utf8.count, 512)
        XCTAssertNil(fields["password"])
        XCTAssertNil(fields["sql"])
        XCTAssertNil(fields["binds"])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret"))
    }
    func testTimedFailureKeepsOutcomeWithoutLoggingErrorContents() throws {
        enum Failure: Error { case secret }
        let buffer = Buffer()
        let sink = JSONLogSink(write: buffer.append)
        sink.level = .info
        let logger = Logger(label: "test") { _ in JSONLogHandler(sink: sink) }
        XCTAssertThrowsError(try ApplicationLog.measure("Read schema", logger: logger) { throw Failure.secret })
        let records = try buffer.snapshot().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(records.count, 2)
        let fields = try XCTUnwrap(records.last?["fields"] as? [String: String])
        XCTAssertEqual(fields["outcome"], "failed")
        XCTAssertNotNil(Double(fields["durationMilliseconds"] ?? ""))
        XCTAssertFalse(String(describing: records).contains("secret"))
    }
    func testConcurrentLogsAndDiagnosticsRemainSeparateRecords() throws {
        let buffer = Buffer()
        let sink = JSONLogSink(write: buffer.append)
        sink.level = .debug
        let logger = Logger(label: "test") { _ in JSONLogHandler(sink: sink) }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 2) {
                try! sink.writeRecord(Data("{\"error\":\"test\"}\n".utf8))
            } else {
                logger.debug("Query finished", metadata: ["outcome": "completed"])
            }
        }
        XCTAssertEqual(buffer.snapshot().count, 100)
        for bytes in buffer.snapshot() { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: bytes)) }
    }
    func testSlowSinkBlocksCallerAndFailedSinkDoesNotThrow() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let sink = JSONLogSink { _ in
            entered.signal()
            release.wait()
        }
        sink.level = .info
        let logger = Logger(label: "test") { _ in JSONLogHandler(sink: sink) }
        DispatchQueue.global().async {
            logger.info("Checkpoint")
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        let failed = JSONLogSink { _ in throw CocoaError(.fileWriteUnknown) }
        let failingLogger = Logger(label: "test") { _ in JSONLogHandler(sink: failed) }
        failingLogger.error("Output unavailable")
    }
}
