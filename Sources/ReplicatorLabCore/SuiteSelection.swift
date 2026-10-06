import Foundation

/// Select independent fixtures, never individual statements of a dependent workload.
public struct SuiteSelection {
    public var build = true
    public var codeCoverage = false
    public var positioning = "both"
    public var slice = "all"
    public var caseIDs: Set<String> = []
    public var list = false
    public init() {}
    public init(arguments: [String], ddl: Bool) throws {
        self.init()
        var args = arguments
        while !args.isEmpty {
            let flag = args.removeFirst()
            if flag == "--skip-build" { build = false; continue }
            if flag == "--coverage" { codeCoverage = true; continue }
            if flag == "--list" { list = true; continue }
            try require(!args.isEmpty, "missing value for " + flag)
            let value = args.removeFirst()
            switch flag {
            case "--positioning": positioning = value
            case "--slice": slice = value
            case "--case": caseIDs.insert(value)
            default: throw LabError("unknown suite option: " + flag)
            }
        }
        try require(["both", "gtid", "file-position"].contains(positioning), "invalid positioning: " + positioning)
        let slices = ddl ? ["all", "basic", "modify-index", "database", "ordered", "filters", "compatibility"] : ["all", "basic", "matrix", "extended", "reconnect", "target-reconnect"]
        try require(slices.contains(slice), "unknown slice; choose " + slices.joined(separator: ", "))
        try require(slice != "extended" || positioning != "file-position", "extended DML fixtures require GTID positioning")
        if !caseIDs.isEmpty {
            try require(ddl ? ["all", "modify-index", "compatibility"].contains(slice) : ["all","matrix"].contains(slice), "--case selects independent fixtures; use --slice for dependent workloads")
            let known = ddl ? Set(Self.independent.map(\.id)) : Set(DMLCompatibilityCases.cases.map{"matrix-"+$0.id} + DMLCompatibilityCases.rejections.map{"matrix-reject-"+$0.id})
            try require(!(ddl && positioning == "file-position" && caseIDs.contains("ddl-compat-types")),"ddl-compat-types requires the GTID/FULL-metadata fixture for ENUM/SET labels")
            try require(caseIDs.isSubset(of: known), "unknown case IDs: " + caseIDs.subtracting(known).sorted().joined(separator: ", "))
            if ddl {
                let compatibility = Set(DDLCompatibilityCases.declarations.map(\.id))
                try require(caseIDs.isSubset(of:compatibility) || caseIDs.isDisjoint(with:compatibility),"cannot mix compatibility and modify-index cases")
                slice = caseIDs.isSubset(of:compatibility) ? "compatibility" : "modify-index"
            } else { slice = "matrix" }
        }
    }
    var modes: [String] { positioning == "both" ? ["file-position", "gtid"] : [positioning] }
    func includes(_ name: String) -> Bool { slice == "all" || slice == name }
    func selects(_ id: String) -> Bool {
        caseIDs.isEmpty || caseIDs.contains(id) || (id == "ddl-index-create" && caseIDs.contains("ddl-index-resume"))
    }
    static var independent: [QualificationCase] {
        DDLCompatibilityCases.declarations + ModifyIndexCases.cases.map(\.test) + ModifyIndexCases.failures.map(\.test) + [ModifyIndexCases.timeout, ModifyIndexCases.resume]
    }
    public func describe(ddl: Bool) {
        print("Slices: " + (ddl ? "all, basic, modify-index, database, ordered, filters, compatibility" : "all, basic, matrix, extended (GTID multirow, discovery, failure and recovery fixtures), reconnect, target-reconnect"))
        print("Every run includes the four-transaction basic DML check used by subsequent fixtures. --positioning gtid|file-position|both (default both).")
        print("--coverage uses an instrumented developer image and exports per-invocation Swift line coverage.")
        if ddl { for test in Self.independent { print(test.description) } }
        else {
            for test in DMLCompatibilityCases.cases { print("matrix-"+test.id) }
            for test in DMLCompatibilityCases.rejections { print("matrix-reject-"+test.id) }
        }
    }
    var fields: [String: Any] { ["slice": slice, "cases": caseIDs.sorted(), "positioning": positioning, "full_suite": slice == "all", "dependencies": ["positive"]] }
}
