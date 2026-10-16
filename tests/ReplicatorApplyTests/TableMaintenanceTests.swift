import Foundation
import XCTest
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class TableMaintenanceTests: XCTestCase {
    func parse(_ sql:String) throws -> DDLStatement {
        try DDLStatement.parse(.init(database:"poc",sql:Data(sql.utf8),errorCode:0,statusVariables:Data()))
    }
    func testMaintenanceUsesTheNormalAlterBarrier() throws {
        let name=TableName(database:"poc",table:"t")
        XCTAssertEqual(try parse("ALTER TABLE t FORCE"),.alter(name,[.maintenance(.force)]))
        XCTAssertEqual(try parse("ALTER TABLE t ENABLE KEYS"),.alter(name,[.maintenance(.enableKeys)]))
        XCTAssertEqual(try parse("ALTER TABLE t DISABLE KEYS, FORCE, ENABLE KEYS"),.alter(name,[.maintenance(.disableKeys),.maintenance(.force),.maintenance(.enableKeys)]))
        XCTAssertNoThrow(try parse("ALTER TABLE t FORCE, ADD v INT, ALGORITHM=COPY"))
    }
    func testBadMaintenanceCannotConsumeFollowingSQL() {
        for sql in ["ENABLE","ENABLE KEY","DISABLE INDEXES","FORCE ENABLE KEYS","FORCE; DROP TABLE t"] {
            XCTAssertThrowsError(try parse("ALTER TABLE t "+sql),sql)
        }
    }
}
