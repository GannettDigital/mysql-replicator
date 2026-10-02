import XCTest
@testable import ReplicatorLabCore

final class CaptureBenchmarkTests: XCTestCase {
    func testBlackholeEvidenceRequiresCompleteDecodeWithoutAppliedProgress() throws {
        let final=Boundary(file:"binlog.000004",position:198,gtids:"sid:1-100")
        let download:[String:Any]=["durable":false,"reachedEOF":true,"eventBytes":1000]
        let capture:[String:Any]=["durableProgress":false,"transactions":100,"completeGTIDSet":final.gtids,
            "eventBytesReceived":"1000","lastCompleteBoundary":["file":final.file,"position":"198"],
            "stageTimings":[:],"download":download]
        let valid:[String:Any]=["kind":"blackhole_summary","writesApplied":0,"durableProgress":false,"rowsDecoded":300,
            "elapsedSeconds":1.0,"capture":capture]
        XCTAssertNoThrow(try CaptureBenchmark.validate(valid,events:100,rowsPerEvent:3,final:final))
        for (key,value):(String,Any) in [("rowsDecoded",299),("writesApplied",100),("durableProgress",true),("elapsedSeconds",0.0)] {
            var bad=valid; bad[key]=value
            XCTAssertThrowsError(try CaptureBenchmark.validate(bad,events:100,rowsPerEvent:3,final:final))
        }
        for (key,value):(String,Any) in [("transactions",99),("completeGTIDSet","sid:1-99"),("eventBytesReceived","999"),
            ("lastCompleteBoundary",["file":final.file,"position":"197"]),("pendingTransactionStart",["file":final.file,"position":"4"]),
            ("download",["durable":false,"reachedEOF":false,"eventBytes":1000])] {
            var bad=valid, changed=capture; changed[key]=value; bad["capture"]=changed
            XCTAssertThrowsError(try CaptureBenchmark.validate(bad,events:100,rowsPerEvent:3,final:final))
        }
    }
}
