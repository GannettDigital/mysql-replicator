import XCTest
import Foundation
@testable import ReplicatorApply
@testable import ReplicatorCodec
@testable import ReplicatorCapture

final class TriggerPolicyTests: XCTestCase {
    func query(_ sql: String, error: UInt32 = 0, status: Data = Data()) -> QueryControl {
        QueryControl(database:"poc",sql:Data(sql.utf8),errorCode:error,statusVariables:status)
    }
    func testSkipPolicyRecognizesOnlyTriggerDefinitionsAndRetainsOriginalSQL() throws {
        let policy = try JSONDecoder().decode(DDLPolicy.self,from:Data("{}".utf8))
        XCTAssertEqual(policy.triggers,"skip"); XCTAssertEqual(policy.events,"reject")
        for sql in [
            "CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW SET NEW.n=NEW.n+1",
            "/* comment */ CREATE DEFINER='root'@'localhost' TRIGGER IF NOT EXISTS poc.tr AFTER UPDATE ON poc.t FOR EACH ROW BEGIN INSERT INTO audit VALUES(NEW.n); DELETE FROM audit WHERE n=0; END",
            "CREATE DEFINER=CURRENT_USER() TRIGGER tr BEFORE DELETE ON t FOR EACH ROW FOLLOWS older SET @x=1",
            "DROP TRIGGER poc.tr;", "DROP TRIGGER IF EXISTS tr"
        ] {
            let skipped = try XCTUnwrap(policy.skippedTrigger(query(sql)))
            XCTAssertEqual(skipped.name,TableName(database:"poc",table:"tr"))
            XCTAssertEqual(skipped.sql,sql); XCTAssertEqual(skipped.reason,"ddlPolicy.triggers=skip")
        }
        for sql in ["CREATE TABLE tr(id INT PRIMARY KEY)","CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO SELECT 1",
                    "CREATE PROCEDURE p() BEGIN DROP TRIGGER tr; END", "ALTER TABLE t ADD n INT"] {
            XCTAssertNil(try policy.skippedTrigger(query(sql)))
        }
        for sql in ["DROP TRIGGER tr; DROP TABLE t", "CREATE TRIGGER tr", "CREATE TRIGGER tr BEFORE INSERT ON other.t FOR EACH ROW SET NEW.n=1",
                    "CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW", "/*!50003 CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW SET NEW.n=1 */"] {
            XCTAssertThrowsError(try policy.skippedTrigger(query(sql)),sql)
        }
        XCTAssertThrowsError(try policy.skippedTrigger(query("DROP TRIGGER tr",error:1)))
        XCTAssertThrowsError(try policy.skippedTrigger(query("DROP TRIGGER tr",status:Data([255]))))
        let reject = try JSONDecoder().decode(DDLPolicy.self,from:Data(#"{"triggers":"reject"}"#.utf8))
        XCTAssertNil(try reject.skippedTrigger(query("DROP TRIGGER tr")))
        XCTAssertThrowsError(try TableFilter().ignores(query("DROP TRIGGER tr")))
        XCTAssertThrowsError(try TableFilter().ignores(query("DROP EVENT e")))
    }
    func testSkipUsesLoggedIdentifierQuotingMode() throws {
        // Q_SQL_MODE: ANSI_QUOTES. Quoted names must not become SQL keywords.
        let status=Data([1,4,0,0,0,0,0,0,0,4,45,0,46,0,46,0])
        let skipped=try DDLPolicy().skippedTrigger(query(#"DROP TRIGGER "poc"."tr""quoted""#,status:status))
        XCTAssertEqual(skipped?.name,TableName(database:"poc",table:"tr\"quoted"))
    }

}

extension ResumeTests {
    func triggerGroup(_ group: CompleteTransaction) -> CompleteTransaction {
        #if os(Linux)
        let ddl=DDLTests(name:"fixtures",testClosure:{_ in})
        #else
        let ddl=DDLTests()
        #endif
        return ddl.ddlGroup(group,sql:"DROP TRIGGER IF EXISTS poc.tr")
    }
    func testSkippedDDLAuditAndCheckpointAreAtomicAndResumeWithoutReplay() throws {
        let path=try directory(),c=try config(path.path),group=triggerGroup(try helper.groups()[0])
        var store:StateStore?=try StateStore(configuration:c)
        try store!.bindTargetIdentity(target)
        for event in group.events { try store!.append(.init(kind:"event",file:group.start.file,observedPosition:String(event.nextPosition),event:event,rawBase64:nil)) }
        guard case .query(let query)=group.events[1].control else {return XCTFail("missing query")}
        let skipped=try XCTUnwrap(DDLPolicy().skippedTrigger(query))
        let db=path.appendingPathComponent("state.sqlite")
        try store!.begin(group)
        try write(path,"CREATE TRIGGER fail_checkpoint BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'injected failure'); END")
        XCTAssertThrowsError(try store!.complete(group,rowCount:0,filtered:true,skippedDDL:skipped))
        XCTAssertEqual(try helper.sqlite(db,"SELECT COUNT(*) FROM ddl_skips"),[["0"]])
        XCTAssertEqual(try helper.sqlite(db,"SELECT status FROM groups"),[["PENDING"]])
        XCTAssertEqual(store!.transactions,0)
        try write(path,"DROP TRIGGER fail_checkpoint")
        try store!.complete(group,rowCount:0,filtered:true,skippedDDL:skipped)
        XCTAssertEqual(try helper.sqlite(db,"SELECT reason,source_sql FROM ddl_skips"),[["ddlPolicy.triggers=skip",skipped.sql]])
        XCTAssertEqual(try helper.sqlite(db,"SELECT transactions_applied,rows_applied,ddl_applied FROM state"),[["1","0","0"]])
        XCTAssertEqual(try helper.sqlite(db,"SELECT COUNT(*) FROM ddl_intents"),[["0"]])
        try store!.stopped(); store=nil
        let resumed=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(resumed.applied,group.end)
        XCTAssertEqual(try resumed.captureConfiguration(c.source).start.executedGTIDs,helper.sid+":1-11")
        XCTAssertThrowsError(try resumed.begin(group))
        XCTAssertEqual(try helper.sqlite(db,"SELECT COUNT(*) FROM ddl_skips"),[["1"]])
    }
    func testFormatSixUpgradeAddsAuditWithoutChangingCheckpoint() throws {
        let path=try directory(),c=try config(path.path)
        try seed(c)
        try write(path,"DROP TABLE replication_profile; DROP TABLE ddl_details; DROP TABLE compatibility; DROP TABLE ddl_skips; PRAGMA user_version=6")
        let store=try StateStore(configuration:c,initialize:false)
        XCTAssertEqual(store.transactions,0)
        XCTAssertEqual(try helper.sqlite(path.appendingPathComponent("state.sqlite"),"PRAGMA user_version"),[["9"]])
        XCTAssertEqual(try helper.sqlite(path.appendingPathComponent("state.sqlite"),"SELECT COUNT(*) FROM ddl_skips"),[["0"]])
    }
    func testSkipAuditPrunesOnlyWithCoveredCompletedGroup() throws {
        let path=try directory(),c=try helper.config(path.path,storage:["historyRetentionSeconds":60])
        var now=Date(timeIntervalSince1970:1_700_000_000),free=Int64.max/4
        let store=try StateStore(configuration:c,now:{now},freeDisk:{_ in free})
        try store.bindTargetIdentity(target)
        let group=triggerGroup(try helper.groups()[0])
        guard case .query(let query)=group.events[1].control else {return XCTFail("missing query")}
        let skipped=try XCTUnwrap(DDLPolicy().skippedTrigger(query))
        try store.begin(group); try store.complete(group,rowCount:0,filtered:true,skippedDDL:skipped)
        try store.stopped()
        let db=path.appendingPathComponent("state.sqlite")
        free=c.policy.minimumFreeDiskBytes+c.policy.maximumSQLiteBytes*3/2
        try store.ensureCapacity()
        XCTAssertEqual(try helper.sqlite(db,"SELECT COUNT(*) FROM ddl_skips"),[["1"]])
        now.addTimeInterval(120); try store.ensureCapacity()
        XCTAssertEqual(try helper.sqlite(db,"SELECT COUNT(*) FROM ddl_skips"),[["0"]])
        XCTAssertEqual(try helper.sqlite(db,"SELECT COUNT(*) FROM groups"),[["0"]])
        XCTAssertEqual(try store.durableAppliedGTIDs(),helper.sid+":1-11")
    }
}
