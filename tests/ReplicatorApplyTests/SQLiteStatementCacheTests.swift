import XCTest
import Foundation
import CSQLite
@testable import ReplicatorApply
@testable import ReplicatorCodec

final class SQLiteStatementCacheTests: XCTestCase {
    private func database(capacity: Int = 64, profiling: Bool = true,
                          _ body: (OpaquePointer,SQLiteStatementCache,StageTimings) throws -> Void) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:",&connection),SQLITE_OK)
        let db=try XCTUnwrap(connection),timings=StageTimings()
        let cache=SQLiteStatementCache(db:db,capacity:capacity,timings:timings,profiling:profiling)
        defer {
            cache.close()
            XCTAssertNil(sqlite3_next_stmt(db,nil),"statement leaked past cache close")
            XCTAssertEqual(sqlite3_close(db),SQLITE_OK)
        }
        try body(db,cache,timings)
    }
    private func count(_ timings: StageTimings, _ stage: String) -> UInt64 {
        timings.snapshot["apply.detail.sqlite."+stage]?.count ?? 0
    }
    func testReuseClearsValuesIncludingOmittedBindingsAndConsumesAllRows() throws {
        try database { db,cache,t in
            let sql="SELECT ? UNION ALL SELECT ?"
            XCTAssertEqual(try cache.query(sql,["old","retained?"]),[["old"],["retained?"]])
            XCTAssertEqual(try cache.query(sql,["new",nil]),[["new"],[nil]])
            XCTAssertEqual(try cache.query(sql),[[nil],[nil]])
            XCTAssertEqual(count(t,"prepare"),1)
            XCTAssertEqual(count(t,"cache_hit"),2)
            XCTAssertEqual(count(t,"reset"),3);XCTAssertEqual(count(t,"clear_bindings"),3)
            XCTAssertEqual(sqlite3_stmt_busy(sqlite3_next_stmt(db,nil)),0)
            cache.close()
            XCTAssertEqual(count(t,"finalize"),1)
            XCTAssertThrowsError(try cache.query(sql))
        }
    }
    func testBoundedLRUEvictsIdleStatementsAndRepreparesOnNextUse() throws {
        try database(capacity:2) { db,cache,t in
            _ = try cache.query("SELECT 1"); _ = try cache.query("SELECT 2")
            _ = try cache.query("SELECT 1") // Keep 1, evict 2.
            _ = try cache.query("SELECT 3")
            XCTAssertEqual(cache.count,2);XCTAssertEqual(count(t,"cache_evict"),1)
            _ = try cache.query("SELECT 1")
            XCTAssertEqual(count(t,"prepare"),3)
            _ = try cache.query("SELECT 2")
            XCTAssertEqual(count(t,"prepare"),4);XCTAssertEqual(count(t,"cache_evict"),2)
            var stmt=sqlite3_next_stmt(db,nil),live=0
            while let current=stmt { live+=1;stmt=sqlite3_next_stmt(db,current) }
            XCTAssertEqual(live,2)
            cache.close();XCTAssertEqual(count(t,"prepare"),count(t,"finalize"))
        }
    }
    func testPragmasAndDDLRemainSingleUseAndSchemaChangesAreObserved() throws {
        try database { _,cache,t in
            _ = try cache.query("CREATE TABLE x(id INTEGER)")
            XCTAssertEqual(try cache.query("PRAGMA user_version"),[["0"]])
            _ = try cache.query("PRAGMA user_version=6")
            XCTAssertEqual(try cache.query("PRAGMA user_version"),[["6"]])
            XCTAssertEqual(cache.count,0)
            XCTAssertEqual(count(t,"prepare"),count(t,"finalize"))
            XCTAssertEqual(try cache.query("SELECT * FROM x"),[])
            _ = try cache.query("ALTER TABLE x ADD COLUMN value TEXT")
            _ = try cache.query("INSERT INTO x VALUES(1,'new column')")
            XCTAssertEqual(try cache.query("SELECT * FROM x"),[["1","new column"]])
            XCTAssertEqual(count(t,"cache_hit"),1)
        }
    }
    func testConstraintAndBindFailuresEvictWithoutRetryOrLeakingBindings() throws {
        try database { _,cache,t in
            _ = try cache.query("CREATE TABLE x(id INTEGER PRIMARY KEY,value TEXT)")
            let insert="INSERT INTO x VALUES(?,?)"
            _ = try cache.query(insert,["1","first"])
            let prepares=count(t,"prepare")
            XCTAssertThrowsError(try cache.query(insert,["1","duplicate"]))
            XCTAssertEqual(count(t,"prepare"),prepares) // One cached execution, no retry.
            _ = try cache.query(insert,["2",nil])
            XCTAssertEqual(count(t,"prepare"),prepares+1)
            let steps=count(t,"step")
            XCTAssertThrowsError(try cache.query(insert,["3","bad","extra binding"]))
            XCTAssertEqual(count(t,"step"),steps) // No execution after bind error.
            _ = try cache.query(insert,["3"])
            XCTAssertEqual(try cache.query("SELECT * FROM x ORDER BY id"),[["1","first"],["2",nil],["3",nil]])
            XCTAssertEqual(t.snapshot["apply.detail.sqlite.step"]?.failures,1)
            XCTAssertEqual(t.snapshot["apply.detail.sqlite.bind"]?.failures,1)
        }
    }
    func testWarmedWriteObservesNewFailureTriggerAndRollbackRemainsReusable() throws {
        for capacity in [0,64] {
            try database(capacity:capacity) { _,cache,t in
                _ = try cache.query("CREATE TABLE x(id INTEGER PRIMARY KEY)")
                let insert="INSERT INTO x VALUES(?)"
                _ = try cache.query(insert,["1"])
                _ = try cache.query("CREATE TRIGGER reject BEFORE INSERT ON x WHEN NEW.id=3 BEGIN SELECT RAISE(ABORT,'injected'); END")
                for _ in 0..<2 {
                    _ = try cache.query("BEGIN IMMEDIATE")
                    _ = try cache.query(insert,["2"])
                    let steps=count(t,"step")
                    XCTAssertThrowsError(try cache.query(insert,["3"]))
                    XCTAssertEqual(count(t,"step"),steps+1)
                    _ = try cache.query("ROLLBACK")
                    XCTAssertEqual(try cache.query("SELECT id FROM x"),[["1"]])
                }
                _ = try cache.query("DROP TRIGGER reject")
                _ = try cache.query("BEGIN IMMEDIATE");_ = try cache.query(insert,["2"]);_ = try cache.query("COMMIT")
                XCTAssertEqual(try cache.query("SELECT id FROM x ORDER BY id"),[["1"],["2"]])
                if capacity == 0 { XCTAssertEqual(cache.count,0) }
            }
        }
    }
    func testProfilingOffStillReusesAndClosesStatements() throws {
        try database(profiling:false) { _,cache,t in
            for i in 0..<5 { XCTAssertEqual(try cache.query("SELECT ?",[String(i)]),[[String(i)]]) }
            XCTAssertEqual(cache.count,1);XCTAssertTrue(t.snapshot.isEmpty)
        }
    }
}
