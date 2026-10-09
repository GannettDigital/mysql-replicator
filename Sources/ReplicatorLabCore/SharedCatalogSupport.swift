import Foundation

/// Explicitly migrated producers for existing logical DDL obligations. Profile
/// IDs and the 730-obligation denominator stay unchanged during the migration.
enum SharedCatalogSupport {
    static var caseIDs: Set<String> {
        Set(DatabaseCreationCases.cases.map { $0.test.id } + ModifyIndexCases.cases.map { $0.test.id } + DDLCoverageCases.changes.map { $0.test.id } + [DDLCoverageCases.group.id])
    }
    static func export(root: URL, output: URL, profile: String, inputs: [String:String], contracts: [String:String], runtime: [String:Any], results: [[String:Any]], result: [String:Any]) throws {
        let directory=output.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let selected=results.filter { ($0["id"] as? String).map(caseIDs.contains) ?? false }
        for test in selected {
            for assertion in test["assertions"] as? [[String:Any]] ?? [] {
                if let path=assertion["evidence"] as? String {
                    try DDLCoverage.safePath(path)
                    let destination=directory.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try FileManager.default.copyItem(at:output.appendingPathComponent(path),to:destination)
                }
            }
        }
        try writeJSON(selected,to:directory.appendingPathComponent("cases.json"))
        try writeJSON(result,to:directory.appendingPathComponent("result.json"))
        try DDLCoverageEvidence.save(root:root,output:directory,profile:profile,inputs:inputs,contracts:contracts,runtime:runtime,results:selected,producer:"shared-correctness")
    }
}

extension SharedCorrectness.Run {
    func assertion(_ id: String, caseID: String, _ body: () throws -> Any) throws {
        try reporter.assertion(id,evidence:"assertions/"+caseID+"/"+id+".json",body)
    }
    func snapshot(_ label: String) throws -> URL {
        let directory=f.output.appendingPathComponent("snapshot-"+label)
        _ = try f.docker(["cp",f.helper+":/evidence/state",directory.path])
        return directory.appendingPathComponent("state.sqlite")
    }
    func state(_ file: URL, _ sql: String) throws -> String {
        try f.runner.run(["sqlite3",file.path,sql]).text
    }
    func binlogAssertion(_ test: ModifyIndexCases.Case, starts: [LabProfile.Role:Boundary]) throws -> Any {
        var observed: [String:[String]] = [:]
        for role in LabProfile.Role.allCases {
            let from=starts[role]!, to=try f.boundary(role)
            try require(from.file == to.file,"unexpected rotation in MODIFY/index comparison")
            let path=f.output.appendingPathComponent(role.rawValue+"-"+test.test.id+".binlog")
            try f.h.compose(["exec","-T",f.profile.service(role),"cat","/var/lib/mysql/"+from.file]).stdout.write(to:path)
            let decoded=try f.runner.run([f.h.decoder,"--no-defaults","--verify-binlog-checksum","--base64-output=DECODE-ROWS","-vv","--start-position=\(from.position)","--stop-position=\(to.position)",path.path])
            try decoded.stdout.write(to:path.appendingPathExtension("txt"))
            let prefixes=["ALTER TABLE ","CREATE INDEX ","CREATE UNIQUE INDEX ","DROP INDEX ","CREATE TABLE ","RENAME TABLE ","TRUNCATE TABLE "]
            let lines=String(decoding:decoded.stdout,as:UTF8.self).components(separatedBy:"\n").filter { line in
                line.hasPrefix("###") || prefixes.contains { line.uppercased().hasPrefix($0) }
            }.map { line in line.range(of:" /*",options:.backwards).map { String(line[..<$0.lowerBound]) } ?? line }
            try require(lines.filter { !$0.hasPrefix("###") }.count == 1 && lines.filter { $0.hasPrefix("### INSERT INTO") || $0.hasPrefix("### UPDATE ") || $0.hasPrefix("### DELETE FROM") }.count == test.workload.reduce(0, { $0+$1.affectedRows }),"missing DDL/DML in normalized binlog")
            if let source=observed["source"] { try require(lines == source,"normalized MODIFY/index binlog differs: "+role.rawValue) }
            observed[role.rawValue]=lines
        }
        return observed
    }
}
