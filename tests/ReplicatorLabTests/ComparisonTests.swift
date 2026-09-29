import XCTest
@testable import ReplicatorLabCore

final class ComparisonTests: XCTestCase {
    func testMissingDuplicateReorderedAndWrongValuesAreRejected() throws {
        let expected = Fixture.operations
        try Comparison.operations(expected, expected: expected)
        var duplicate = expected; duplicate.insert(expected[0], at: 1)
        var reordered = expected; reordered.swapAt(0, 1)
        var wrong = expected; wrong[3].after![2] = "18446744073709551614"
        for corrupted in [Array(expected.dropFirst()), duplicate, reordered, wrong] {
            XCTAssertThrowsError(try Comparison.operations(corrupted, expected: expected))
        }
    }
    func testTransientInsertDeleteCannotDisappearEvenWhenFinalRowsAgree() {
        let transient = [RowOperation("insert", after: ["7", "temporary", "7"]),
                         RowOperation("delete", before: ["7", "temporary", "7"])]
        XCTAssertThrowsError(try Comparison.operations([], expected: transient))
    }
    func testPrematureCompletedCheckpointIsRejected() {
        var advanced = observation()
        advanced.status["Exec_Source_Log_Pos"] = "200"
        advanced.reachedEnd = true
        advanced.gtidCovered = true
        XCTAssertThrowsError(try advanced.validate(expectedRejection: true, autoPosition: false))
    }
    func observation() -> NativeObservation {
        NativeObservation(sourceRows: Fixture.final, nativeRows: Fixture.partial, targetRows: Fixture.seed,
                          status: ["Auto_Position": "0", "Last_IO_Errno": "0", "Replica_IO_Running": "Yes",
                                   "Read_Source_Log_Pos": "200", "Exec_Source_Log_Pos": "100",
                                   "Last_SQL_Errno": "1837", "Last_SQL_Error": "GTID_NEXT consumed",
                                   "Replica_SQL_Running": "No"],
                          startPosition: "100", endPosition: "200", reachedEnd: false, gtidCovered: false)
    }
    func testExpectedRejectionNeedsExactErrorAndPartialEffects() throws {
        try observation().validate(expectedRejection: true, autoPosition: false)
        var wrongError = observation(); wrongError.status["Last_SQL_Errno"] = "1062"
        var noInsert = observation(); noInsert.nativeRows = Fixture.seed
        var tooManyWrites = observation(); tooManyWrites.nativeRows = Fixture.final
        var advanced = observation(); advanced.status["Exec_Source_Log_Pos"] = "200"
        var falseCompletion = observation(); falseCompletion.gtidCovered = true
        for invalid in [wrongError, noInsert, tooManyWrites, advanced, falseCompletion] {
            XCTAssertThrowsError(try invalid.validate(expectedRejection: true, autoPosition: false))
        }
    }
    func testInfrastructureFailureCannotPassAsNativeRejection() {
        var disconnected = observation(); disconnected.status["Last_IO_Errno"] = "1236"
        var lagging = observation(); lagging.status["Read_Source_Log_Pos"] = "150"
        var missingField = observation(); missingField.status["Last_SQL_Errno"] = nil
        for invalid in [disconnected, lagging, missingField] {
            XCTAssertThrowsError(try invalid.validate(expectedRejection: true, autoPosition: false))
        }
    }
    func testPositiveRequiresRowsAndGTIDCoverage() throws {
        var positive = observation()
        positive.nativeRows = Fixture.final; positive.reachedEnd = true; positive.gtidCovered = true
        positive.status["Last_SQL_Errno"] = "0"; positive.status["Replica_SQL_Running"] = "Yes"
        positive.status["Exec_Source_Log_Pos"] = "200"
        try positive.validate(expectedRejection: false, autoPosition: false)
        positive.gtidCovered = false
        XCTAssertThrowsError(try positive.validate(expectedRejection: false, autoPosition: false))
    }
}
