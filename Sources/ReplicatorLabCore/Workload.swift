import Foundation

public struct RowOperation: Codable, Equatable {
    public var kind: String
    public var before: [String]?
    public var after: [String]?
    public init(_ kind: String, before: [String]? = nil, after: [String]? = nil) {
        self.kind = kind; self.before = before; self.after = after
    }
}

public enum Fixture {
    public static let seed = [["1", "seed-one", "1"], ["2", "seed-two", "2"]]
    public static let inserted = ["3", "inserted", "18446744073709551615"]
    public static let final = [["1", "updated", "1"], ["3", "final-three", "18446744073709551615"]]
    public static let partial = seed + [inserted]
    public static let operations = [
        RowOperation("insert", after: inserted),
        RowOperation("update", before: seed[0], after: final[0]),
        RowOperation("delete", before: seed[1]),
        RowOperation("update", before: inserted, after: final[1])
    ]
    public static func sql(transaction: Bool) -> String {
        (transaction ? "BEGIN;\n" : "") + """
        INSERT INTO poc.items VALUES (3,'inserted',18446744073709551615);
        UPDATE poc.items SET value='updated' WHERE id=1;
        DELETE FROM poc.items WHERE id=2;
        """ + (transaction ? "\nCOMMIT;" : "") + """

        BEGIN;
        INSERT INTO poc.items VALUES (4,'rolled-back',4);
        ROLLBACK;
        UPDATE poc.items SET value='final-three' WHERE id=3;
        """
    }
}

public enum Comparison {
    public static func operations(_ actual: [RowOperation], expected: [RowOperation]) throws {
        try require(actual.count == expected.count, "operation multiplicity differs: \(actual.count) versus \(expected.count)")
        for (index, pair) in zip(actual, expected).enumerated() {
            try require(pair.0 == pair.1, "operation/value/order differs at ordinal \(index)")
        }
    }
}

public struct NativeObservation {
    public var sourceRows: [[String]]
    public var nativeRows: [[String]]
    public var targetRows: [[String]]
    public var status: [String: String]
    public var startPosition: String
    public var endPosition: String
    public var reachedEnd: Bool
    public var gtidCovered: Bool
    public init(sourceRows: [[String]], nativeRows: [[String]], targetRows: [[String]],
                status: [String: String], startPosition: String, endPosition: String,
                reachedEnd: Bool, gtidCovered: Bool) {
        self.sourceRows = sourceRows; self.nativeRows = nativeRows; self.targetRows = targetRows
        self.status = status; self.startPosition = startPosition; self.endPosition = endPosition
        self.reachedEnd = reachedEnd; self.gtidCovered = gtidCovered
    }
    public func validate(expectedRejection: Bool, autoPosition: Bool) throws {
        try require(sourceRows == Fixture.final, "source does not match committed workload intent")
        try require(targetRows == Fixture.seed, "future Swift target changed without an applier")
        try require(status["Auto_Position"] == (autoPosition ? "1" : "0"), "wrong positioning mode")
        try require(status["Last_IO_Errno"] == "0" && status["Replica_IO_Running"] == "Yes", "receiver failure is not an expected SQL rejection")
        try require(status["Read_Source_Log_Pos"] == endPosition, "receiver did not reach source end")
        if expectedRejection {
            try require(status["Last_SQL_Errno"] == "1837", "wrong native rejection")
            try require(status["Last_SQL_Error"]?.contains("GTID_NEXT") == true, "missing GTID diagnostic")
            try require(status["Replica_SQL_Running"] == "No", "native SQL thread did not stop")
            try require(nativeRows == Fixture.partial, "wrong partial effects after native rejection")
            try require(status["Exec_Source_Log_Pos"] == startPosition && !reachedEnd && !gtidCovered, "native advanced through the rejected workload")
        } else {
            try require(status["Last_SQL_Errno"] == "0" && status["Replica_SQL_Running"] == "Yes", "unexpected native SQL failure")
            try require(nativeRows == Fixture.final && reachedEnd && gtidCovered, "native convergence or GTID coverage failed")
            try require(status["Exec_Source_Log_Pos"] == endPosition, "native completion boundary differs")
        }
    }
}
