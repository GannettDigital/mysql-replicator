import XCTest
@testable import ReplicatorLabCore

final class LabProfileTests: XCTestCase {
    func testMySQL57MyISAMReusesCapabilitiesAndSharedScenarios() throws {
        let profile=LabProfile.mysql57MyISAM
        XCTAssertEqual(profile.sourceVersion,.mysql57)
        XCTAssertEqual(profile.targetVersion,.mysql57)
        XCTAssertEqual(profile.nativeVersion,.mysql57)
        XCTAssertFalse(profile.transactionalTarget)
        XCTAssertFalse(profile.hasOptionalMetadata)
        XCTAssertFalse(profile.supportsPositionCapture)
        for id in ["myisam-recovery","offline-replay","live-skip-errors","ddl-compat-temporary"] {
            XCTAssertNil(try XCTUnwrap(LabScenario.correctness.first { $0.id == id }).reason(profile))
        }
        for id in ["reverse-database-table-defaults","forward-failures"] {
            XCTAssertNotNil(try XCTUnwrap(LabScenario.correctness.first { $0.id == id }).reason(profile))
        }
        let demo=LabDemoQualification.scenarios.filter { $0.applies(profile) }.map(\.id)
        XCTAssertEqual(demo.count,11)
        XCTAssertTrue(demo.contains("demo-fail-stop"))
        XCTAssertTrue(demo.contains("demo-resume-applied-gtid"))
        XCTAssertFalse(demo.contains("demo-resume-applied-position"))
        XCTAssertNotNil(LabVariant.positionMinimal.reason(profile))
        XCTAssertNoThrow(try LabTestOptions(["--profile",profile.rawValue,"--suite","recovery","--coverage"]))
        XCTAssertThrowsError(try LabBenchmark.Options(["--profile",profile.rawValue,"--workload","multi-table-transaction"]))
    }
    func testServerDialectDoesNotDependOnEngine() {
        let boundary=Boundary(file:"binlog.000003",position:123,gtids:"")
        for profile in LabProfile.allCases {
            let version=profile.nativeVersion
            let sql=version.connect(host:profile.service(.source),caFile:"/ca.pem",boundary:boundary,autoPosition:true)
            XCTAssertTrue(sql.contains(version.sourcePrefix+"AUTO_POSITION=1"))
            XCTAssertTrue(version.position(boundary).contains(version.sourcePrefix+"LOG_POS=123"))
            XCTAssertEqual(version.startReplica,profile.sourceVersion == .mysql57 ? "START SLAVE" : "START REPLICA")
        }
    }

    func testLogicalRolesAndNativeReferencesAreExplicit() {
        XCTAssertEqual(LabProfile.forward.version(.native),"8.4")
        XCTAssertEqual(LabProfile.reverse.version(.native),"5.7")
        for profile in LabProfile.allCases {
            XCTAssertEqual(Set(profile.topology.compactMap{$0["service"]}).count,3)
            XCTAssertEqual(profile.engine(.source),"InnoDB")
            XCTAssertEqual(profile.engine(.native),profile.engine(.target))
        }
    }
    func testSharedCatalogHasStableUniqueIDsAndSmokeCoversCoreFamilies() throws {
        let cases=LabScenario.correctness
        XCTAssertEqual(cases.count,80+DMLCompatibilityCases.cases.count+DMLCompatibilityCases.rejections.count)
        XCTAssertEqual(Set(cases.map(\.id)).count,cases.count)
        for (id,family) in [("offline-skip-errors","offline"),("live-skip-errors","policy")] {
            let skipping=try XCTUnwrap(cases.first { $0.id == id })
            XCTAssertEqual(skipping.family,family)
            for profile in LabProfile.allCases { XCTAssertNil(skipping.reason(profile)) }
            XCTAssertNotNil(skipping.reason(.forward,variant:.positionMinimal))
        }
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
    func testOrderedWorkflowCannotBeSelectedAsIncompleteSteps() throws {
        XCTAssertEqual(try LabScenario.select(tier:"full",family:"ordered",ids:[]).map(\.id),["ddl"])
        XCTAssertThrowsError(try LabScenario.select(tier:"full",family:nil,ids:["create-if-matching"]))
        XCTAssertEqual(DDLCoverageCases.changes.count,70)
        let collation=LabScenario.correctness.filter { $0.family == "collation" }
        XCTAssertEqual(collation.count,2)
        XCTAssertTrue(collation.allSatisfy { $0.reason(.forward) == nil && $0.reason(.reverse) != nil })
    }
    func testSharedSelectionsKeepDependentPhasesTogetherAndRejectRetiredSuites() throws {
        for phase in [DDLCompatibilityCases.collationCleanupInitial,DDLCompatibilityCases.collationCleanupChanged,DDLCompatibilityCases.collationCleanupRemoved] {
            XCTAssertTrue(DDLCoverageCases.registry.contains { $0.test.id == phase.id })
            XCTAssertThrowsError(try LabScenario.select(tier:"full",family:nil,ids:[phase.id]))
        }
        let matrix=try LabScenario.select(tier:"full",family:"bootstrap",ids:["bootstrap-matrix-decimal"])
        XCTAssertEqual(matrix.map(\.id),["bootstrap-matrix-decimal"])
        XCTAssertEqual(try DMLCompatibilityCases.transactionCount("a:1-3:5,b:9-10"),6)
        XCTAssertEqual(try DMLCompatibilityCases.transactionCount(""),0)
        for suite in ["legacy-dml","legacy-ddl"] { XCTAssertThrowsError(try LabTestOptions(["--suite",suite])) }
        XCTAssertFalse(try LabTestOptions([]).coverage)
        let options=try LabTestOptions(["--coverage","--skip-build","--case","positive"])
        XCTAssertTrue(options.coverage); XCTAssertFalse(options.build)
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
            XCTAssertThrowsError(try LabProfile.takeProfile(&args))
        }
        var args=["example.sql","--profile",LabProfile.forward.rawValue]
        XCTAssertEqual(try LabProfile.takeProfile(&args),.forward)
        XCTAssertEqual(args,["example.sql"])
    }
    func testVersionAdaptationsAreDeclaredByFixtures() {
        let charset=DatabaseCreationCases.cases.first { $0.test.id == "database-charset-only" }!
        XCTAssertEqual(charset.prefix57,"")
        XCTAssertFalse(charset.prefix.isEmpty)
        let temporary=DDLCompatibilityCases.cases.first { $0.test.id == "ddl-compat-temporary" }!
        XCTAssertTrue(temporary.steps.contains { $0.sql.contains("ENGINE=MyISAM") && $0.sqlTransactional.contains("ENGINE=InnoDB") })
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
    func testVersionSessionSettingsFollowEachServerRole() {
        for profile in LabProfile.allCases {
            for role in LabProfile.Role.allCases {
                let session=profile.session(role), legacy=profile.version(role) == "5.7"
                XCTAssertEqual(session.contains("NO_AUTO_CREATE_USER"),legacy)
                XCTAssertEqual(session.contains("default_collation_for_utf8mb4"),!legacy)
            }
        }
    }
    func testFailureWorkflowsExposeChildrenAndCannotPassWithMissingEvidence() throws {
        for (id,children) in [("forward-failures",SharedWorkflowCases.failures),("myisam-recovery",SharedWorkflowCases.recovery)] {
            let scenario=try XCTUnwrap(LabScenario.correctness.first { $0.id == id })
            let declared=try XCTUnwrap(scenario.fields(.forward)["ordered_steps"] as? [[String:Any]])
            XCTAssertEqual(declared.compactMap { $0["id"] as? String },children.map(\.id))
            XCTAssertEqual(Set(children.map(\.id)).count,children.count)
            XCTAssertNotNil(scenario.reason(.reverse))
            let results=children.map { ["id":$0.id,"status":"passed"] as [String:Any] }
            XCTAssertNoThrow(try SharedWorkflowCases.requirePassed(children,in:results))
            XCTAssertThrowsError(try SharedWorkflowCases.requirePassed(children,in:Array(results.dropLast())))
        }
        let options=try LabTestOptions(["--profile",LabProfile.forward.rawValue,"--suite","recovery","--coverage","--variant","gtid-full"])
        XCTAssertTrue(options.coverage)
        let recovery=try XCTUnwrap(LabScenario.correctness.first { $0.id == "myisam-recovery" })
        XCTAssertNotNil(recovery.reason(.forward,variant:.positionMinimal))
    }
    func testHistoricalVariantsPreserveStartContractsAndApplicability() throws {
        let boundary=Boundary(file:"binlog.000004",position:123,gtids:"uuid:1-3")
        XCTAssertNil(LabVariant.gtidFull.start(boundary)["file"])
        XCTAssertEqual(LabVariant.gtidFull.start(boundary)["executedGTIDs"] as? String,"uuid:1-3")
        XCTAssertEqual(LabVariant.positionMinimal.start(boundary)["position"] as? UInt64,123)
        XCTAssertEqual(LabVariant.positionMinimal.mode,"file-position")
        XCTAssertEqual(LabVariant.positionMinimal.start(boundary)["executedGTIDs"] as? String,"uuid:1-3")
        XCTAssertEqual(try LabTestOptions(["--variant","all"]).variants,LabVariant.allCases)
        XCTAssertThrowsError(try LabTestOptions(["--variant","unknown"]))
        XCTAssertThrowsError(try LabTestOptions(["--suite","recovery","--variant","gtid-full"]))
        XCTAssertTrue(LabLifecycle.fields(.reverse,variant:.gtidFull).allSatisfy { $0["status"] as? String == "not_applicable" && $0["reason"] is String })
        let types=try XCTUnwrap(LabScenario.correctness.first { $0.id == "ddl-compat-types" })
        XCTAssertEqual(types.fields(.forward,variant:.positionMinimal)["status"] as? String,"not_applicable")
        XCTAssertEqual(types.fields(.forward,variant:.gtidFull)["status"] as? String,"not_run")
    }
    func testDemoCatalogPreservesWorkflowsAndProfileApplicability() throws {
        let all=LabDemoQualification.scenarios
        XCTAssertEqual(Set(all.map(\.id)).count,14)
        let selected=try LabDemoQualification.select(family:nil,ids:["demo-modify-index"])
        XCTAssertEqual(selected.map(\.id),all.prefix(7).filter { $0.id != "demo-container-repair" }.map(\.id))
        XCTAssertEqual(try LabDemoQualification.select(family:nil,ids:["demo-reverse-recovery"]).map(\.id),["demo-reverse-workbook","demo-reverse-recovery"])
        XCTAssertEqual(all.filter { $0.fields(.forward)["status"] as? String == "not_run" }.count,11)
        XCTAssertEqual(all.filter { $0.fields(.reverse)["status"] as? String == "not_run" }.count,10)
        XCTAssertThrowsError(try LabDemoQualification.select(family:"resume",ids:["demo-success"]))
        XCTAssertTrue(try LabTestOptions(["--suite","demo","--coverage","--case","demo-idle-sigint"]).coverage)
    }
    func testBenchmarkRoutingRequiresAnExplicitProfileAndMode() throws {
        let forward=LabProfile.forward.rawValue, reverse=LabProfile.reverse.rawValue
        XCTAssertThrowsError(try LabBenchmark.Options([]))
        let backlog=try LabBenchmark.Options(["--profile",reverse,"--events","100","--workload","multi-table-transaction"])
        XCTAssertEqual(backlog.mode,"backlog"); XCTAssertEqual(backlog.events,100)
        XCTAssertEqual(backlog.batchTransactions,8)
        XCTAssertTrue(backlog.applierProfiling); XCTAssertFalse(backlog.decoderProfiling)
        let profiled=try LabBenchmark.Options(["--profile",reverse,"--decoder-profile","on","--applier-profile","off","--batch-transactions","32"])
        XCTAssertTrue(profiled.decoderProfiling); XCTAssertFalse(profiled.applierProfiling)
        XCTAssertEqual(profiled.batchTransactions,32)
        for mode in ["streaming","capture"] {
            let options=try LabBenchmark.Options(["--mode",mode,"--profile",forward,"--threads","2"])
            XCTAssertEqual(options.forwardedArguments,["--threads","2"])
            XCTAssertThrowsError(try LabBenchmark.Options(["--mode",mode,"--profile",reverse]))
        }
        for args in [["--mode","invalid"],["--mode","backlog","--mode","capture"],["--events","0"],["--threads","2"],["--workload","multi-table-transaction"],["--batch-transactions","0"],["--batch-transactions","257"],["--decoder-profile","yes"],["--applier-profile","yes"]] {
            XCTAssertThrowsError(try LabBenchmark.Options(["--profile",forward]+args))
        }
    }

}
