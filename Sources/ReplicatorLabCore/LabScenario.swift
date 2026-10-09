import Foundation

/// A scenario is an ordered experiment, never an individual SQL statement.
struct LabScenario {
    let test: QualificationCase
    let family: String
    var dependencies: [String] = []
    var reverseOnly = false
    var forwardOnlyReason: String?
    var intent: String = "apply"
    var smoke = false
    var id: String { test.id }
    func reason(_ profile: LabProfile, variant: LabVariant = .standard) -> String? {
        if let reason=variant.reason(profile) { return reason }
        if ["offline-replay","offline-skip-errors","runtime-control"].contains(id) && variant == .positionMinimal { return "Offline replay uses GTID positioning; use default or gtid-full variants." }
        if profile == .reverse, let reason=forwardOnlyReason { return reason }
        if variant == .positionMinimal && id == "myisam-recovery" { return "Historical discovery/recovery workflow is GTID-only; positional capture is qualified by correctness and lifecycle variants." }
        if variant == .positionMinimal && id == "ddl-compat-types" { return "ENUM/SET type fixture requires FULL optional metadata; retained in gtid-full." }
        return reverseOnly && profile == .forward ? "Exercises a multi-table source transaction outside the MyISAM apply contract; its refusal is qualified by myisam-recovery." : nil
    }
    func fields(_ profile: LabProfile, variant: LabVariant = .standard) -> [String:Any] {
        var value=test.fields
        value["profile"]=profile.rawValue; value["variant"]=variant.rawValue; value["family"]=family
        value["dependencies"]=dependencies; value["intent"]=intent
        value["expected"]=["source":"accept","native":"apply","applier":intent]
        if family == "failures" || family == "recovery" { value["expected"]=["source":"accept","native":"per-case success or expected rejection","applier":intent] }
        if id == "myisam-recovery" { value["ordered_steps"]=SharedWorkflowCases.recovery.map { $0.fields } }
        if id == "forward-failures" { value["ordered_steps"]=SharedWorkflowCases.failures.map { $0.fields } }
        if id == DDLCoverageCases.group.id { value["ordered_steps"]=DDLCoverageCases.changes.map { $0.test.fields } }
        if family == "bootstrap", let fixture=DMLCompatibilityCases.cases.first(where:{id == "bootstrap-matrix-"+$0.id}) { value["phase_count"]=fixture.phases.count }
        value["status"]=reason(profile,variant:variant) == nil ? "not_run" : "not_applicable"
        if let reason=reason(profile,variant:variant) { value["reason"]=reason }
        value["setup"]=["bootstrap","dml-refusals","discovery","failures","recovery","ordered","collation","filters"].contains(family) || id == "positive" ? "equivalent unlogged table snapshots; isolated state and saved-state resume" : "replicated DDL; baseline reverse_poc tables are bootstrapped"
        return value
    }
    static var correctness: [LabScenario] {
        var cases=DatabaseCreationCases.cases.map { test -> LabScenario in
            var item=LabScenario(test:test.test,family:"database")
            if test.existing { item.dependencies=["database-explicit"] }
            item.smoke=test.test.id == "database-explicit"
            return item
        }
        cases.append(.init(test:.init("reverse-database-table-defaults","Defaults, multi-table transaction, implicit DDL commit and table swap"),family:"database",dependencies:["database-charset-only"],reverseOnly:true))
        cases += DDLCompatibilityCases.cases.map { .init(test:$0.test,family:"ddl",smoke:["ddl-compat-types","ddl-compat-database"].contains($0.test.id)) }
        cases += DMLCompatibilityCases.cases.map { .init(test:.init("matrix-"+$0.id,"Shared DML matrix: "+$0.id),family:"dml",smoke:$0.id == "composite") }
        cases += ModifyIndexCases.cases.map { .init(test:$0.test,family:"indexes",smoke:$0.test.id == "ddl-index-create") }
        cases.append(.init(test:.init("offline-replay","Fetch, external raw replay, resume, and sensitive support evidence"),family:"offline"))
        cases.append(.init(test:.init("offline-skip-errors","Optional skip audit, pre-write DDL rejection, InnoDB rollback/continue and MyISAM refusal"),family:"offline",intent:"skip listed unwritten errors; skip duplicate GTID only after InnoDB rollback"))
        cases.append(.init(test:.init("runtime-control","Exact GTID limits, reload, status, and graceful stop"),family:"offline"))
        cases.append(.init(test:DDLCompatibilityCases.skipTrigger,family:"policy",intent:"skip definitions; apply row effects",smoke:true))
        cases += ["enum-non-bmp","set-non-bmp","engine","foreign-key","event","trigger","float","json"].map {
            .init(test:.init("reject-"+$0,"Reject unsupported DDL: "+$0),family:"rejections",intent:"reject before target SQL",smoke:$0 == "json")
        }
        cases += [
            .init(test:DDLCoverageCases.wildcardFilter,family:"filters",intent:"skip excluded events; apply included rows",smoke:true),
            .init(test:DDLCoverageCases.wildcardResume,family:"filters",dependencies:[DDLCoverageCases.wildcardFilter.id],intent:"resume saved filter state"),
            .init(test:DDLCoverageCases.wildcardRejection,family:"filters",dependencies:[DDLCoverageCases.wildcardResume.id],intent:"reject included DDL before target SQL")
        ]
        cases.append(.init(test:DDLCoverageCases.group,family:"ordered"))
        cases += [DDLCompatibilityCases.collationCleanup,DDLCompatibilityCases.collationCollision].map {
            .init(test:$0,family:"collation",forwardOnlyReason:"Requires 8.4 source 0900/NO PAD collations and 5.7 mapping; these collations do not exist on a 5.7 source.")
        }
        cases.append(.init(test:DDLCoverageCases.positive,family:"dml",smoke:true))
        cases += DMLCompatibilityCases.cases.map { .init(test:.init("bootstrap-matrix-"+$0.id,"Discover bootstrapped DML schema: "+$0.id),family:"bootstrap") }
        cases += DMLCompatibilityCases.rejections.map { .init(test:.init("matrix-reject-"+$0.id,"Refuse incompatible bootstrapped metadata: "+$0.id),family:"dml-refusals",forwardOnlyReason:"Historical 8.4 metadata and 5.7 MyISAM effect contract; reverse optional-label and rollback expectations require separate assertions.",intent:"reject with unchanged durable progress") }
        cases.append(.init(test:ModifyIndexCases.resume,family:"discovery"))
        cases.append(.init(test:.init("forward-failures","Forward DDL/policy failures retain pending evidence and blocked following writes"),family:"failures",forwardOnlyReason:"Historical 8.4 to 5.7 MyISAM grants, index limits and native error codes.",intent:"per-case apply or fail-stop"))
        cases.append(.init(test:.init("myisam-recovery","MyISAM discovery, exact values, cache, failures and crash/replay refusal"),family:"recovery",forwardOnlyReason:"MyISAM partial persistence and native 1837 contract; InnoDB rollback/retry is qualified by the reverse recovery suite.",intent:"per-case apply or fail-stop"))
        return cases
    }
    static func select(tier: String, family: String?, ids: Set<String>) throws -> [LabScenario] {
        let all=correctness, known=Set(all.map(\.id))
        try require(ids.isSubset(of:known),"unknown cases: " + ids.subtracting(known).sorted().joined(separator:", "))
        if let family { try require(Set(all.map(\.family)).contains(family),"unknown correctness family: "+family) }
        var selected=Set(all.filter { (family == nil || $0.family == family) && (ids.isEmpty ? tier == "full" || $0.smoke : ids.contains($0.id)) }.map(\.id))
        try require(ids.isEmpty || selected == ids,"selected cases do not belong to the requested family")
        var prior: Set<String> = []
        while prior != selected {
            prior=selected
            for item in all where selected.contains(item.id) { selected.formUnion(item.dependencies) }
        }
        return all.filter { selected.contains($0.id) }
    }
}
