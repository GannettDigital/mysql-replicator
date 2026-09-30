import Foundation

/// Capture the location where a scenario is defined, not where it is logged.
struct QualificationCase {
    let id: String
    let name: String
    let file: String
    let line: UInt

    init(_ id: String, _ name: String, file: String = #filePath, line: UInt = #line) {
        self.id = id
        self.name = name
        let components = file.split(separator: "/")
        if let start = components.lastIndex(where: { $0 == "Sources" || $0 == "tests" }) {
            self.file = components[start...].joined(separator: "/")
        } else {
            self.file = file
        }
        self.line = line
    }

    var description: String { "[\(id)] \(name) (\(file):\(line))" }
    var fields: [String: Any] { ["id": id, "name": name, "source_file": file, "source_line": line] }
}

/// Writes incremental evidence so a failed assertion retains its scenario identity.
final class QualificationReporter {
    private let output: URL
    private let log: (String) -> Void
    private var active: [(test: QualificationCase, index: Int)] = []
    private(set) var results: [[String: Any]] = []

    init(output: URL, log: @escaping (String) -> Void) {
        self.output = output
        self.log = log
    }

    func begin(_ test: QualificationCase) throws {
        try require(!results.contains { $0["id"] as? String == test.id }, "duplicate qualification case ID: \(test.id)")
        var result = test.fields
        result["status"] = "running"
        if let parent = active.last { result["parent_id"] = parent.test.id }
        active.append((test, results.count))
        results.append(result)
        log("starting " + test.description)
        try save()
    }

    func pass(_ id: String) throws {
        guard let current = active.last, current.test.id == id else {
            throw LabError("qualification case completion out of order: \(id)")
        }
        results[current.index]["status"] = "passed"
        try save()
        active.removeLast()
        log("passed " + current.test.description)
    }

    func run(_ test: QualificationCase, _ body: () throws -> Void) throws {
        try begin(test)
        try body()
        try pass(test.id)
    }

    /// Mark every unfinished enclosing case failed; preserve the original assertion.
    func fail(_ error: Error) -> Error {
        let detail = String(describing: error)
        let identified = active.last.map { LabError($0.test.description + ": " + detail) }
        for current in active.reversed() {
            results[current.index]["status"] = "failed"
            results[current.index]["error"] = detail
            log("failed " + current.test.description + ": " + detail)
        }
        active.removeAll()
        do { try save() } catch { log("could not save case results: \(error)") }
        return identified ?? error
    }

    private func save() throws {
        try writeJSON(results, to: output.appendingPathComponent("cases.json"))
    }
}
