import XCTest
@testable import ReplicatorApply

extension ApplyTests {
    func testCapacityInspectionIntervalsAndLegacyDefaults() throws {
        let defaults = try config().policy
        XCTAssertEqual(defaults.capacityCheckEveryTransactions,1000)
        XCTAssertEqual(defaults.capacityCheckIntervalSeconds,5)
        for interval in [1000,10000] {
            var policy = defaults; policy.capacityCheckEveryTransactions = interval
            try policy.validate()
            var window = CapacityWindow()
            func due(_ sequence: Int64, _ time: Double) -> Bool {
                window.needsInspection(sequence:sequence,time:time,relay:0,incoming:0,
                    growth:0,databaseLimit:80*1024*1024,policy:policy)
            }
            XCTAssertTrue(due(7,10))
            window.record(sequence:7,time:10,relay:0,free:4*1024*1024*1024,used:4096)
            XCTAssertFalse(due(Int64(interval)+6,14.99))
            XCTAssertTrue(due(Int64(interval)+7,14.99))
            XCTAssertTrue(due(7,15))
        }
        for storage in [["capacityCheckEveryTransactions":0],["capacityCheckEveryTransactions":10001],
                        ["capacityCheckIntervalSeconds":0],["capacityCheckIntervalSeconds":61]] {
            XCTAssertThrowsError(try config(storage:storage).policy.validate())
        }
    }

    func testCapacityInspectionAcceleratesForDatabaseAndRelayGrowth() {
        let policy = StoragePolicy(), databaseLimit: Int64 = 80*1024*1024
        let used: Int64 = 4096, margin: Int64 = 100000
        var window = CapacityWindow()
        window.record(sequence:0,time:10,relay:50,
            free:policy.minimumFreeDiskBytes+policy.maximumSQLiteBytes*2+margin,used:used)
        func due(relay: UInt64 = 50, incoming: Int64 = 0, growth: Int64 = 0) -> Bool {
            window.needsInspection(sequence:0,time:10,relay:relay,incoming:incoming,
                growth:growth,databaseLimit:databaseLimit,policy:policy)
        }
        XCTAssertFalse(due())
        XCTAssertFalse(due(incoming:margin-1))
        XCTAssertTrue(due(incoming:margin))
        XCTAssertTrue(due(relay:UInt64(margin)+50))
        XCTAssertFalse(due(growth:databaseLimit*80/100-used-1))
        XCTAssertTrue(due(growth:databaseLimit*80/100-used))
    }

    func testCachedCapacityStillBoundsWALWithoutCompletedGroups() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        var inspections = 0, time = Date()
        let store = try StateStore(configuration:config(parent.appendingPathComponent("state").path),now:{time},uptime:{10},freeDisk:{ _ in
            inspections += 1; return 4*1024*1024*1024
        })
        try store.running()
        let checkpoints = store.timings.snapshot["sqlite.checkpoint"]!.count
        inspections = 0
        for _ in 0..<400 {
            time.addTimeInterval(1)
            try store.running()
            XCTAssertLessThan(store.walBytes,store.checkpointThreshold+16384)
        }
        XCTAssertEqual(store.transactions,0)
        XCTAssertEqual(inspections,0)
        XCTAssertGreaterThan(store.timings.snapshot["sqlite.checkpoint"]!.count,checkpoints)
    }

    func testCapacityTimerDetectsExternalDiskPressureBeforeNextWrite() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:parent) }
        var time = 10.0, free: Int64 = 4*1024*1024*1024
        let store = try StateStore(configuration:config(parent.appendingPathComponent("state").path),uptime:{time},freeDisk:{_ in free})
        try store.running()
        let commits = store.timings.snapshot["sqlite.commit"]!.count
        free = 0; time = 15
        XCTAssertThrowsError(try store.running()) { XCTAssertTrue(String(describing:$0).contains("free-disk reserve")) }
        XCTAssertEqual(store.timings.snapshot["sqlite.commit"]!.count,commits)
        free = store.policy.minimumFreeDiskBytes+store.policy.maximumSQLiteBytes*2-1
        try store.running()
        let inspections = store.timings.snapshot["storage.free_space"]!.count
        try store.running()
        XCTAssertEqual(store.timings.snapshot["storage.free_space"]!.count,inspections+1)
    }
}
