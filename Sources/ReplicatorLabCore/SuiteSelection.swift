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
        let slices = ddl ? ["all", "basic", "modify-index", "database", "ordered", "filters"] : ["all", "basic"]
        try require(slices.contains(slice), "unknown slice; choose " + slices.joined(separator: ", "))
        if !caseIDs.isEmpty {
            try require(ddl && ["all", "modify-index"].contains(slice), "--case selects independent MODIFY/index fixtures; use --slice for dependent workloads")
            let known = Set(Self.independent.map(\.id))
            try require(caseIDs.isSubset(of: known), "unknown case IDs: " + caseIDs.subtracting(known).sorted().joined(separator: ", "))
            slice = "modify-index"
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
        print("Slices: " + (ddl ? "all, basic, modify-index, database, ordered, filters" : "all, basic"))
        print("Every run includes the four-transaction basic DML check used by subsequent fixtures. --positioning gtid|file-position|both (default both).")
        if ddl { for test in Self.independent { print(test.description) } }
    }
    var fields: [String: Any] { ["slice": slice, "cases": caseIDs.sorted(), "positioning": positioning, "full_suite": slice == "all", "dependencies": ["positive"]] }
}
