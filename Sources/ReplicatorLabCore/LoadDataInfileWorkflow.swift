import Foundation

/// Import on the source; reuse the running applier and the group's containers.
enum LoadDataInfileWorkflow {
    static let test = QualificationCase("dml-load-data-infile", "LOAD DATA INFILE: source file import and replicated rows")
    static let table = "poc.load_data_infile"
    static let phase = DDLExecutionPhase(
        id: "load-source-operations",
        steps: [
            .init("CREATE TABLE \(table)(id INT PRIMARY KEY,v INT NOT NULL) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"),
            .init(
                "SELECT 1,10 UNION ALL SELECT 2,20 INTO OUTFILE '/var/lib/mysql-files/replicator-dml.tsv'",
                transactions: 0),
            .init(
                "LOAD DATA INFILE '/var/lib/mysql-files/replicator-dml.tsv' INTO TABLE \(table)",
                phaseEnd: "load-source-operations"),
        ])
    static let observations = DDLFinalObservations(
        checks: [
            .init(id: "load-import-count-and-sum", check: .init("SELECT COUNT(*)=2 AND SUM(v)=30 FROM \(table)", "1")),
            .init(id: "load-imported-rows", check: .init("SELECT id,v FROM \(table) ORDER BY id", "1\t10\n2\t20")),
        ], databases: ["poc"], cleanup: [])
    static var assertions: [String] {
        [phase.id] + observations.checks.map(\.id) + ["final-schema-poc", "load-applied-checkpoint"]
    }
    static func validateSource(_ writes: [LabSQLPhase.Result]) throws -> [Int] {
        let batch = DMLExecutionWorkflow.Batch(
            id: phase.id, writes: phase.writes(transactional: false), transactions: [1, 0, 1])
        let counts = try batch.validate(writes)
        try require(phase.validateUnlogged(writes) == 1, "LOAD DATA export changed the source binlog")
        return counts
    }
    static func validateProgress(before: [String: Any], after: [String: Any], end: Boundary) throws {
        for (key, expected) in [("transactionsApplied", 2), ("ddlApplied", 1), ("rowsApplied", 2)] {
            guard let old = before[key] as? Int, let new = after[key] as? Int else {
                throw LabError("missing LOAD DATA counter: " + key)
            }
            try require(new - old == expected, "LOAD DATA counter differs: " + key)
        }
        guard let position = after["appliedPosition"] as? [String: Any], let offset = position["position"] else {
            throw LabError("missing LOAD DATA applied position")
        }
        try require(
            after["appliedGTIDSet"] as? String == end.gtids && position["file"] as? String == end.file
                && String(describing: offset) == String(end.position), "LOAD DATA checkpoint differs")
    }
}

extension SharedCorrectness.Run {
    func loadDataInfile() throws {
        let test = LoadDataInfileWorkflow.test
        guard selects(test.id) else { return }
        try reporter.run(test) {
            guard let before = try applier.latestProgress() else { throw LabError("missing LOAD DATA initial progress") }
            var writes: [LabSQLPhase.Result] = []
            try assertion(LoadDataInfileWorkflow.phase.id, caseID: test.id) {
                writes = try sourcePhase(
                    test.id, writes: LoadDataInfileWorkflow.phase.writes(transactional: false), database: "poc")
                return [
                    "writes": writes.map(\.json),
                    "transactionCounts": try LoadDataInfileWorkflow.validateSource(writes),
                ] as [String: Any]
            }
            try ddlFinalObservations(LoadDataInfileWorkflow.observations, caseID: test.id)
            try assertion("load-applied-checkpoint", caseID: test.id) {
                guard let after = try applier.latestProgress(), let end = writes.last?.end else {
                    throw LabError("missing LOAD DATA applied progress")
                }
                try LoadDataInfileWorkflow.validateProgress(before: before, after: after, end: end)
                return ["before": before, "after": after, "source": end.json] as [String: Any]
            }
        }
    }
}
