import Foundation

/// Select independent fixtures, never individual statements of a dependent workload.
public struct SuiteSelection {
    public var build = true
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
        let slices = ddl ? ["all", "basic", "modify-index", "database", "ordered", "filters"] : ["all", "basic", "matrix", "extended"]
        try require(slices.contains(slice), "unknown slice; choose " + slices.joined(separator: ", "))
        try require(slice != "extended" || positioning != "file-position", "extended DML fixtures require GTID positioning")
        if !caseIDs.isEmpty {
            try require(ddl ? ["all", "modify-index"].contains(slice) : ["all","matrix"].contains(slice), "--case selects independent fixtures; use --slice for dependent workloads")
            let known = ddl ? Set(Self.independent.map(\.id)) : Set(DMLCompatibilityCases.cases.map{"matrix-"+$0.id} + DMLCompatibilityCases.rejections.map{"matrix-reject-"+$0.id})
            try require(caseIDs.isSubset(of: known), "unknown case IDs: " + caseIDs.subtracting(known).sorted().joined(separator: ", "))
            slice = ddl ? "modify-index" : "matrix"
        }
    }
    var modes: [String] { positioning == "both" ? ["file-position", "gtid"] : [positioning] }
    func includes(_ name: String) -> Bool { slice == "all" || slice == name }
    func selects(_ id: String) -> Bool {
        caseIDs.isEmpty || caseIDs.contains(id) || (id == "ddl-index-create" && caseIDs.contains("ddl-index-resume"))
    }
    static var independent: [QualificationCase] {
        ModifyIndexCases.cases.map(\.test) + ModifyIndexCases.failures.map(\.test) + [ModifyIndexCases.timeout, ModifyIndexCases.resume]
    }
    public func describe(ddl: Bool) {
        print("Slices: " + (ddl ? "all, basic, modify-index, database, ordered, filters" : "all, basic, matrix, extended (GTID multirow, discovery, failure and recovery fixtures)"))
        print("Every run includes the four-transaction basic DML check used by subsequent fixtures. --positioning gtid|file-position|both (default both).")
        if ddl { for test in Self.independent { print(test.description) } }
        else {
            for test in DMLCompatibilityCases.cases { print("matrix-"+test.id) }
            for test in DMLCompatibilityCases.rejections { print("matrix-reject-"+test.id) }
        }
    }
    var fields: [String: Any] { ["slice": slice, "cases": caseIDs.sorted(), "positioning": positioning, "full_suite": slice == "all", "dependencies": ["positive"]] }
}
