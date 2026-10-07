import Foundation

/// A scenario is an ordered experiment, never an individual SQL statement.
struct LabScenario {
    let test: QualificationCase
    let family: String
    var dependencies: [String] = []
    var reverseOnly = false
    var intent: String = "apply"
    var smoke = false
    var id: String { test.id }
    func reason(_ profile: LabProfile, variant: LabVariant = .standard) -> String? {
        if let reason=variant.reason(profile) { return reason }
        if variant == .positionMinimal && id == "ddl-compat-types" { return "ENUM/SET type fixture requires FULL optional metadata; retained in gtid-full." }
        return reverseOnly && profile == .forward ? "Exercises a multi-table source transaction outside the MyISAM apply contract; its refusal remains in legacy DML qualification." : nil
    }
    func fields(_ profile: LabProfile, variant: LabVariant = .standard) -> [String:Any] {
        var value=test.fields
        value["profile"]=profile.rawValue; value["variant"]=variant.rawValue; value["family"]=family
        value["dependencies"]=dependencies; value["intent"]=intent
        value["expected"]=["source":"accept","native":"apply","applier":intent]
        value["status"]=reason(profile,variant:variant) == nil ? "not_run" : "not_applicable"
        if let reason=reason(profile,variant:variant) { value["reason"]=reason }
        value["setup"]=family == "filters" ? "equivalent unlogged table snapshots; isolated state and saved-state resume" : "replicated DDL; baseline reverse_poc tables are bootstrapped"
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
        cases += DDLCompatibilityCases.cases.map { .init(test:$0.test,family:"ddl",smoke:$0.test.id == "ddl-compat-types") }
        cases += DMLCompatibilityCases.cases.map { .init(test:.init("matrix-"+$0.id,"Shared DML matrix: "+$0.id),family:"dml",smoke:$0.id == "composite") }
        cases += ModifyIndexCases.cases.map { .init(test:$0.test,family:"indexes",smoke:$0.test.id == "ddl-index-create") }
        cases.append(.init(test:DDLCompatibilityCases.skipTrigger,family:"policy",intent:"skip definitions; apply row effects",smoke:true))
        cases += ["enum-non-bmp","set-non-bmp","engine","foreign-key","event","trigger","float","json"].map {
            .init(test:.init("reject-"+$0,"Reject unsupported DDL: "+$0),family:"rejections",intent:"reject before target SQL",smoke:$0 == "json")
        }
        cases += [
            .init(test:DDLCoverageCases.wildcardFilter,family:"filters",intent:"skip excluded events; apply included rows",smoke:true),
            .init(test:DDLCoverageCases.wildcardResume,family:"filters",dependencies:[DDLCoverageCases.wildcardFilter.id],intent:"resume saved filter state"),
            .init(test:DDLCoverageCases.wildcardRejection,family:"filters",dependencies:[DDLCoverageCases.wildcardResume.id],intent:"reject included DDL before target SQL")
        ]
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
