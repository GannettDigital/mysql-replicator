import XCTest
@testable import ReplicatorApply
@testable import ReplicatorCodec

extension ApplyTests {
    func testPlanningCacheChecksChangedMetadataAndInvalidatesReplacement() throws {
        let table = tables()[0]
        var cache = try DMLPlanningCache([table.identity:table])
        var event = try groups()[0].events.first { $0.eventType == 19 }!
        let wire = [
            WireColumn(interpretation:.signed,type:3,maximumBytes:0,nullable:false,collation:0,primaryKey:true,name:"id"),
            WireColumn(interpretation:.utf8,type:15,maximumBytes:400,nullable:false,collation:224,primaryKey:false,name:"value"),
            WireColumn(interpretation:.unsigned,type:8,maximumBytes:0,nullable:false,collation:0,primaryKey:false,name:"quantity")]
        event.wireColumns = wire
        XCTAssertEqual(try cache.validate(event),table)
        XCTAssertEqual(try cache.validate(event),table)
        // Full descriptor equality guards cache hits, including optional name,
        // key flag, signedness, collation and width. Failed validation is not cached.
        for changed in [
            WireColumn(interpretation:.utf8,type:15,maximumBytes:400,nullable:true,collation:224,primaryKey:false,name:"value"),
            WireColumn(interpretation:.utf8,type:15,maximumBytes:400,nullable:false,collation:46,primaryKey:false,name:"value"),
            WireColumn(interpretation:.utf8,type:15,maximumBytes:404,nullable:false,collation:224,primaryKey:false,name:"value"),
            WireColumn(interpretation:.utf8,type:15,maximumBytes:400,nullable:false,collation:224,primaryKey:true,name:"value"),
            WireColumn(interpretation:.utf8,type:15,maximumBytes:400,nullable:false,collation:224,primaryKey:false,name:"other")
        ] {
            event.wireColumns![1] = changed
            XCTAssertThrowsError(try cache.validate(event))
            XCTAssertThrowsError(try cache.validate(event))
            event.wireColumns = wire
            XCTAssertEqual(try cache.validate(event),table)
        }
        event.wireColumns![0] = WireColumn(interpretation:.unsigned,type:3,maximumBytes:0,nullable:false,collation:0,primaryKey:true,name:"id")
        XCTAssertThrowsError(try cache.validate(event))
        event.wireColumns = wire
        var columns = table.columns
        columns[1] = ApplyColumn(name:"value",type:"varchar(101)",nullable:false,collation:"utf8mb4_unicode_ci")
        try cache.insert(table.replacing(columns:columns))
        XCTAssertThrowsError(try cache.validate(event)) // old metadata cannot hit
        cache = try DMLPlanningCache() // ordered DDL/drop clears identities
        XCTAssertThrowsError(try cache.validate(event))
    }
    func testCachedPlansPreserveValueValidationAndMutationOrder() throws {
        let table = tables()[0], cache = try DMLPlanningCache([table.identity:table])
        for group in try groups() {
            let cached = try DMLPlan.make(group,tables:cache.tables)
            let original = try DMLPlan.make(group,tables:tables())
            XCTAssertEqual(cached.map(\.row),original.map(\.row))
            XCTAssertEqual(cached.map(\.eventOffset),original.map(\.eventOffset))
            XCTAssertEqual(cached.map(\.rowIndex),original.map(\.rowIndex))
        }
        let plan = cache.tables[table.identity]!
        try plan.validate([.signed(1),.text("okay"),.unsigned(UInt64.max)])
        for values: [DecodedValue] in [
            [.signed(Int64(Int32.max)+1),.text("okay"),.unsigned(1)],
            [.signed(1),.null,.unsigned(1)],
            [.signed(1),.text(String(repeating:"x",count:101)),.unsigned(1)],
            [.signed(1),.text("okay"),.signed(1)], [.signed(1)]
        ] { XCTAssertThrowsError(try plan.validate(values)) }
    }
    func testCachedDecimalMetadataRejectsChangedPrecisionAndSignedness() throws {
        let table = ApplyTable(database:"poc",table:"items",columns:[ApplyColumn(name:"d",type:"decimal(20,6)",nullable:true,collation:nil)],primaryKey:"d")
        var cache = try DMLPlanningCache([table.identity:table])
        var event = try groups()[0].events.first { $0.eventType == 19 }!
        var wire = WireColumn(interpretation:.decimal,type:246,maximumBytes:0,nullable:true,collation:0,primaryKey:true,name:"d",metadata:Data([20,6]),isUnsigned:false)
        event.wireColumns = [wire]; _ = try cache.validate(event)
        wire.metadata = Data([20,5]); event.wireColumns = [wire]
        XCTAssertThrowsError(try cache.validate(event))
        wire.metadata = Data([20,6]); wire.isUnsigned = true; event.wireColumns = [wire]
        XCTAssertThrowsError(try cache.validate(event))
    }
}
