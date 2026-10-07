import XCTest
@testable import ReplicatorLabCore

final class LabProfileTests: XCTestCase {
    func testLogicalRolesAndNativeReferencesAreExplicit() {
        XCTAssertEqual(LabProfile.forward.version(.native),"8.4")
        XCTAssertEqual(LabProfile.reverse.version(.native),"5.7")
        for profile in LabProfile.allCases {
            XCTAssertEqual(Set(profile.topology.compactMap{$0["service"]}).count,3)
            XCTAssertEqual(profile.engine(.source),"InnoDB")
            XCTAssertEqual(profile.engine(.native),profile.engine(.target))
        }
    }
    func testSharedCatalogHasStableUniqueIDsAndSmokeCoversEveryFamily() throws {
        let cases=LabScenario.correctness
        XCTAssertEqual(cases.count,68)
        XCTAssertEqual(Set(cases.map(\.id)).count,cases.count)
        do {
            let smoke=try LabScenario.select(tier:"smoke",family:nil,ids:[])
            XCTAssertEqual(Set(smoke.map(\.family)),Set(["database","ddl","dml","indexes","policy","rejections","filters"]))
        }
    }
    func testSelectionClosesDependenciesButDoesNotSelectUnrelatedCases() throws {
        let cases=try LabScenario.select(tier:"full",family:nil,ids:["database-existing-matching"])
        XCTAssertEqual(Set(cases.map(\.id)),["database-existing-matching","database-explicit"])
        XCTAssertThrowsError(try LabScenario.select(tier:"full",family:nil,ids:["typo"]))
        XCTAssertThrowsError(try LabScenario.select(tier:"full",family:"dml",ids:["ddl-index-create"]))
    }
    func testFilterSelectionPreservesTheOrderedResumeWorkflowOnBothProfiles() throws {
        let cases=try LabScenario.select(tier:"full",family:"filters",ids:["wild-ignore-included-rejection"])
        XCTAssertEqual(cases.map(\.id),["wild-ignore","wild-ignore-resume","wild-ignore-included-rejection"])
        for profile in LabProfile.allCases {
            XCTAssertTrue(cases.allSatisfy { $0.fields(profile)["status"] as? String == "not_run" })
        }
        XCTAssertThrowsError(try LabScenario.select(tier:"full",family:"rejections",ids:["wild-ignore-included-rejection"]))
    }
    func testLifecycleRunsTheSameDeclaredCasesOnBothProfiles() {
        let forward=LabLifecycle.fields(.forward), reverse=LabLifecycle.fields(.reverse)
        XCTAssertEqual(forward.compactMap{$0["id"] as? String},reverse.compactMap{$0["id"] as? String})
        XCTAssertEqual(Set(reverse.compactMap{$0["id"] as? String}).count,11)
        XCTAssertTrue((forward+reverse).allSatisfy{$0["status"] as? String == "not_run"})
        XCTAssertEqual(reverse.first{$0["id"] as? String == "target-drain-resume"}?["dependencies"] as? [String],["target-drain"])
        XCTAssertEqual(reverse.first{$0["id"] as? String == "target-uncertain-resume"}?["dependencies"] as? [String],["target-uncertain"])
        let fk=LabScenario.correctness.first{$0.id == "reject-foreign-key"}!
        XCTAssertEqual(fk.fields(.reverse)["status"] as? String,"not_run")
        XCTAssertEqual(fk.intent,"reject before target SQL")
    }
    func testAggregateDoesNotHideMissingCasesOrCleanupFailures() {
        XCTAssertEqual(LabTests.aggregate(rows:[["status":"passed"]],failed:true),"failed")
        for status in ["not_run","not_implemented","running","unknown"] {
            XCTAssertEqual(LabTests.aggregate(rows:[["status":"passed"],["status":status]],failed:false),"incomplete")
        }
        XCTAssertEqual(LabTests.aggregate(rows:[["status":"passed"],["status":"not_applicable"]],failed:false),"passed")
    }
    func testDemoRequiresOneExplicitProfile() throws {
        for var args in [[], ["--profile","all"], ["--profile",LabProfile.reverse.rawValue,"--profile",LabProfile.forward.rawValue]] {
            XCTAssertThrowsError(try LabDemo.takeProfile(&args))
        }
        var args=["example.sql","--profile",LabProfile.forward.rawValue]
        XCTAssertEqual(try LabDemo.takeProfile(&args),.forward)
        XCTAssertEqual(args,["example.sql"])
    }
    func testVersionAdaptationsAreDeclaredByFixtures() {
        let charset=DatabaseCreationCases.cases.first { $0.test.id == "database-charset-only" }!
        XCTAssertEqual(charset.prefix57,"")
        XCTAssertFalse(charset.prefix.isEmpty)
        let temporary=DDLCompatibilityCases.cases.first { $0.test.id == "ddl-compat-temporary" }!
        XCTAssertTrue(temporary.steps.contains { $0.sql.contains("ENGINE=MyISAM") && $0.sql57.contains("ENGINE=InnoDB") })
    }
    func testInvalidSelectionsFailBeforeProvisioning() {
        for args in [["--suite","demo","--tier","smoke"],["--profile","wrong"],["--suite","wrong"],["--tier","wrong"],["--suite","demo","--case","matrix-values"],["--coverage","--suite","recovery"]] {
            XCTAssertThrowsError(try LabTestOptions(args))
        }
    }
    func testLifecycleAllowsInstrumentedRuns() throws {
        let options=try LabTestOptions(["--suite","lifecycle","--coverage"])
        XCTAssertTrue(options.coverage)
        XCTAssertEqual(options.profiles,LabProfile.allCases)
    }
    func testHistoricalVariantsPreserveStartContractsAndApplicability() throws {
        let boundary=Boundary(file:"binlog.000004",position:123,gtids:"uuid:1-3")
        XCTAssertNil(LabVariant.gtidFull.start(boundary)["file"])
        XCTAssertEqual(LabVariant.gtidFull.start(boundary)["executedGTIDs"] as? String,"uuid:1-3")
        XCTAssertEqual(LabVariant.positionMinimal.start(boundary)["position"] as? UInt64,123)
        XCTAssertEqual(LabVariant.positionMinimal.mode,"file-position")
        XCTAssertEqual(try LabTestOptions(["--variant","all"]).variants,LabVariant.allCases)
        XCTAssertThrowsError(try LabTestOptions(["--variant","unknown"]))
        XCTAssertThrowsError(try LabTestOptions(["--suite","recovery","--variant","gtid-full"]))
        XCTAssertTrue(LabLifecycle.fields(.reverse,variant:.gtidFull).allSatisfy { $0["status"] as? String == "not_applicable" && $0["reason"] is String })
        let types=try XCTUnwrap(LabScenario.correctness.first { $0.id == "ddl-compat-types" })
        XCTAssertEqual(types.fields(.forward,variant:.positionMinimal)["status"] as? String,"not_applicable")
        XCTAssertEqual(types.fields(.forward,variant:.gtidFull)["status"] as? String,"not_run")
    }
}
