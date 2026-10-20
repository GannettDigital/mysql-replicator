import Foundation
import XCTest

@testable import ReplicatorApply
@testable import ReplicatorCodec

extension ApplyTests {
    func testSQLSelectionJournalIsAddedToExistingFormat14State() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let configuration = try config(parent.appendingPathComponent("state").path, transport: "binlog")
        do {
            let store = try StateStore(configuration: configuration)
            try store.bindTargetIdentity("11111111-1111-1111-1111-111111111111")
            try store.running()
            try store.stopped()
        }
        let db = parent.appendingPathComponent("state/state.sqlite")
        try writeGTIDTestState(db, "DROP TRIGGER prune_sql_transport; DROP TABLE sql_transport_groups")
        do { _ = try StateStore(configuration: configuration, initialize: false) }
        XCTAssertEqual(try sqlite(db, "SELECT COUNT(*) FROM sql_transport_groups"), [["0"]])
        XCTAssertEqual(try sqlite(db, "SELECT mode,program_version FROM target_transport"), [["binlog", "1"]])
        XCTAssertEqual(try sqlite(db, "PRAGMA user_version"), [["14"]])
    }

    func testSQLSelectionUsesWholeGroupMetadataAndExplicitPolicy() throws {
        let group = try groups()[0]
        let mutations = try DMLPlan.make(group, tables: tables())
        func select(_ events: [DecodedEvent], _ policy: CompatibilityPolicy = .init()) -> DMLSQLReason? {
            DMLSQLReason.select(
                .init(
                    start: group.start, end: group.end, gtid: group.gtid, anonymous: group.anonymous,
                    outcome: group.outcome, events: events), mutations: mutations, compatibility: policy)
        }
        XCTAssertNil(select(group.events))
        var filtered = group.events
        filtered[2].replicationFiltered = true
        XCTAssertEqual(select(filtered), .filteredGroup)
        var mapped = group.events
        let index = try XCTUnwrap(mapped.firstIndex { $0.eventType == 19 })
        mapped[index].wireColumns = [
            .init(
                interpretation: nil, type: 15, maximumBytes: 100,
                nullable: false, collation: 255, primaryKey: false, name: "val")
        ]
        XCTAssertNil(select(mapped))
        XCTAssertEqual(select(mapped, .init(collations: ["utf8mb4_0900_ai_ci": "utf8mb4_bin"])), .collationMapping)
        var columns = mutations[0].table.columns
        columns[1].generationExpression = "id + 1"
        let table = ApplyTable(database: "poc", table: "items", columns: columns, primaryKey: "id")
        let mutation = Mutation(table: table, row: mutations[0].row, eventOffset: "4", rowIndex: 0)
        XCTAssertEqual(DMLSQLReason.select(group, mutations: [mutation], compatibility: .init()), .generatedColumns)
        let partial = DecodedEvent(
            offset: "4", eventSize: 100, control: nil, rowFlags: 1,
            eventType: 39, eventName: "PARTIAL_UPDATE_ROWS_EVENT", timestamp: 0,
            serverID: 1, nextPosition: 104, flags: 0, sha256: "", tableID: "1",
            database: "poc", table: "items", number: nil, detailBase64: nil,
            detailText: nil, rows: [], rawBase64: nil)
        XCTAssertEqual(select(group.events + [partial]), .partialJSON)
    }

    func testJSONYearSelectionIncludesBeforeImagesAndRequiresOptIn() throws {
        let group = try groups()[0]
        let year = try JSONDocument(
            source: Data(
                #"{"text":"null","typed":[{"path":"$","type":13,"value":"","rawHex":"32303236","precision":0,"scale":0}]}"#
                    .utf8))
        for operation in ["insert", "update", "delete"] {
            let values: [DecodedValue] = [.json(year)]
            let row = DecodedRow(
                operation: operation, before: operation == "insert" ? nil : values,
                after: operation == "insert" ? values : nil)
            let mutation = Mutation(table: tables()[0], row: row, eventOffset: "4", rowIndex: 0)
            XCTAssertNil(DMLSQLReason.select(group, mutations: [mutation], compatibility: .init()))
            XCTAssertEqual(
                DMLSQLReason.select(
                    group, mutations: [mutation],
                    compatibility: .init(jsonYearToInteger: true)), .jsonYear)
        }
        XCTAssertNoThrow(
            try config(
                profile: "mysql57-to-mysql84-innodb", jsonYearToInteger: true,
                transport: "binlog"
            ).validate())
        // An ordinary YEAR column or a JSON integer does not need this conversion.
        let row = DecodedRow(operation: "insert", before: nil, after: [.json(try JSONDocument(text: "2026"))])
        let mutation = Mutation(table: tables()[0], row: row, eventOffset: "4", rowIndex: 0)
        XCTAssertNil(DMLSQLReason.select(group, mutations: [mutation], compatibility: .init(jsonYearToInteger: true)))
    }

    func testSQLSelectionIsDurableBeforeWritesAndRemovedWithDiscardedGroups() throws {
        try withBatchFixture { state, input in
            var groups = input
            groups[1].sqlReason = .jsonYear
            try state.beginBatch(groups)
            let db = state.directory.appendingPathComponent("state.sqlite")
            XCTAssertEqual(
                try sqlite(db, "SELECT gtid,reason FROM sql_transport_groups"), [[groups[1].id, "json-year"]])
            XCTAssertEqual(try sqlite(db, "SELECT COUNT(*) FROM row_intents WHERE status='PENDING'"), [["4"]])
            XCTAssertEqual(state.transactions, 0)
            try state.discardUnwrittenPending()
            XCTAssertEqual(try sqlite(db, "SELECT COUNT(*) FROM sql_transport_groups"), [["0"]])
        }
    }

    func testTransportChangesFlushOnlyAtSourceTransactionBoundaries() throws {
        try withBatchFixture { _, input in
            var groups = input
            let data = try Data(
                contentsOf: root.appendingPathComponent("tests/ReplicatorLabTests/Fixtures/source-positive.binlog"))
            let length = (0..<4).reduce(0) { $0 | Int(data[13 + $1]) << (8 * $1) }
            let program = try BinlogEventProgram(
                format: data.subdata(in: 4..<4 + length),
                events: groups[0].group.events.filter { [19, 30, 31, 32].contains($0.eventType) }
                    .map { Data(base64Encoded: $0.rawBase64!)! },
                maximumPacketBytes: 1024 * 1024, maximumRawBytes: 1024 * 1024,
                transactionalTarget: true, preserveSourceGTIDs: true)
            groups[0].binlog = program
            groups[1].sqlReason = .filteredGroup
            groups[2].sqlReason = .generatedColumns
            groups[3].binlog = program
            var batches: [[String]] = []
            var reasons: [String] = []
            let batch = DMLBatch(policy: .init(), uptime: { 0 }, onFlush: { reasons.append($0) }) {
                batches.append($0.map(\.id))
            }
            for group in groups { try batch.append(group) }
            try batch.flush()
            XCTAssertEqual(batches, [[groups[0].id], [groups[1].id, groups[2].id], [groups[3].id]])
            XCTAssertEqual(reasons, ["transport", "transport", "explicit"])
        }
    }
}
