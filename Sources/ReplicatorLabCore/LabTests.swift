import Foundation

public enum LabTests {
    public static func run(root: URL, arguments: [String]) throws {
        let options=try LabTestOptions(arguments)
        let suites=options.suite == "all" ? ["correctness","lifecycle","recovery","demo","native"] : [options.suite]
        var rows: [[String:Any]]=[]
        for profile in options.profiles {
            for suite in suites where !(options.suite == "all" && !profile.transactionalTarget && suite == "recovery") {
              for variant in options.variants {
                if suite == "correctness" {
                    rows += try LabScenario.select(tier:options.tier,family:options.family,ids:options.ids).map { item in
                        var row=item.fields(profile,variant:variant); row["suite"]=suite; return row
                    }
                } else if suite == "demo" {
                    rows += try LabDemoQualification.select(family:options.family,ids:options.ids).map { $0.fields(profile) }
                } else if suite == "recovery" && !profile.transactionalTarget {
                    var row=LabScenario.correctness.first { $0.id == "myisam-recovery" }!.fields(profile,variant:variant)
                    row["suite"]=suite; rows.append(row)
                } else if suite == "lifecycle" { rows += LabLifecycle.fields(profile,variant:variant) }
                else { rows.append(adapter(profile:profile,suite:suite)) }
              }
            }
        }
        if options.list {
            try printJSON(["schema_version":1,"selection":options.suite,"tier":options.tier,"profiles":options.profiles.map { ["id":$0.rawValue,"topology":$0.topology] as [String:Any] },"scenarios":rows])
            return
        }
        let inputs=try DDLCoverageEvidence.inputs(root:root)
        let directory=root.appendingPathComponent("artifacts/lab/"+runID())
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var report: [String:Any]=["schema_version":1,"suite":options.suite,"tier":options.tier,"scope":"Selected scenario obligations; not complete MySQL feature qualification","result":"running", "build_inputs_digest":try DDLCoverageEvidence.digest(inputs), "code_coverage":options.coverage, "requested_cases":options.ids.sorted(), "requested_family":options.family ?? "all", "profiles":options.profiles.map { ["id":$0.rawValue,"topology":$0.topology] as [String:Any] }]
        func save() throws { report["scenarios"]=rows; try writeJSON(report,to:directory.appendingPathComponent("result.json")) }
        try save()
        var failed=false
        var image: String?
        for profile in options.profiles {
            for suite in suites where !(options.suite == "all" && !profile.transactionalTarget && suite == "recovery") {
              for variant in options.variants {
                let indices=rows.indices.filter { rows[$0]["profile"] as? String == profile.rawValue && rows[$0]["suite"] as? String == suite && (rows[$0]["variant"] as? String ?? "default") == variant.rawValue }
                guard indices.contains(where:{rows[$0]["status"] as? String == "not_run"}) else { continue }
                do {
                    if suite == "demo" {
                        let demoImage=try LabBuild.prepare(root:root,build:options.build,coverage:options.coverage,demo:true)
                        let category="lab/"+directory.lastPathComponent+"/"+profile.rawValue+"/demo/default"
                        let selected=Set(indices.filter { rows[$0]["status"] as? String == "not_run" }.compactMap { rows[$0]["id"] as? String })
                        let run=try LabDemoQualification.Run(root:root,profile:profile,category:category,image:demoImage,coverage:options.coverage,selected:selected)
                        var error: Error?
                        do { try run.execute() } catch let e { error=e }
                        for i in indices where rows[i]["status"] as? String == "not_run" {
                            let observed=run.reporter.results.first { $0["id"] as? String == rows[i]["id"] as? String }
                            rows[i]["status"]=observed?["status"] ?? "not_run"; rows[i]["evidence"]=run.output.path
                            if let detail=observed?["error"] { rows[i]["error"]=detail }
                        }
                        if let error { throw error }
                        try require(indices.allSatisfy { ["passed","not_applicable"].contains(rows[$0]["status"] as? String ?? "") },"demo runner omitted selected cases")
                    } else if suite == "correctness" || suite == "lifecycle" || (suite == "recovery" && !profile.transactionalTarget) {
                        if image == nil { image=try LabBuild.prepare(root:root,build:options.build,coverage:options.coverage); report["image"]=image }
                        let selected=Set(indices.filter { rows[$0]["status"] as? String == "not_run" }.compactMap { rows[$0]["id"] as? String })
                        let reporter: QualificationReporter, output: URL, execute: () throws -> Void
                        let category="lab/"+directory.lastPathComponent+"/"+profile.rawValue+"/"+suite+"/"+variant.rawValue
                        if suite != "lifecycle" {
                            let run=SharedCorrectness.Run(root:root,profile:profile,selected:selected,category:category,image:image!,codeCoverage:options.coverage,variant:variant)
                            reporter=run.reporter; output=run.f.output; execute={ try run.execute(build:false,slice:"all") }
                        } else {
                            let run=LabLifecycle.Run(root:root,profile:profile,category:category,image:image!,codeCoverage:options.coverage,variant:variant)
                            reporter=run.reporter; output=run.f.output; execute={ try run.execute() }
                        }
                        var error: Error?
                        do { try execute() } catch let e { error=e }
                        for i in indices where rows[i]["status"] as? String == "not_run" {
                            let observed=reporter.results.first { $0["id"] as? String == rows[i]["id"] as? String }
                            rows[i]["status"]=observed?["status"] ?? "not_run"
                            rows[i]["evidence"]=output.path
                            if let detail=observed?["error"] { rows[i]["error"]=detail }
                        }
                        if let error { throw error }
                        try require(indices.allSatisfy { ["passed","not_applicable"].contains(rows[$0]["status"] as? String ?? "") },"runner omitted selected scenario obligations")
                    } else {
                        let i=indices[0]; rows[i]["status"]="running"; try save()
                        var evidence: [String]=[]
                        defer { rows[i]["evidence"]=evidence }
                        try runAdapter(root:root,profile:profile,suite:suite,build:options.build,onEvidence:{ evidence.append($0.path) })
                        rows[i]["status"]="passed"
                    }
                } catch {
                    failed=true
                    report[profile.rawValue+"/"+suite+"/"+variant.rawValue+"/error"]=String(describing:error)
                    for i in indices where rows[i]["status"] as? String == "running" { rows[i]["status"]="failed"; rows[i]["error"]=String(describing:error) }
                }
                try save()
              }
            }
        }
        if try DDLCoverageEvidence.inputs(root:root) != inputs {
            failed=true; report["input_error"]="Checkout inputs changed while the lab was running; rerun qualification."
        }
        report["result"]=aggregate(rows:rows,failed:failed)
        try save()
        print("Lab \(report["result"]!): \(directory.path)/result.json")
        try require(report["result"] as? String == "passed","selected lab obligations did not all pass; see result.json")
    }

    static func aggregate(rows: [[String:Any]], failed: Bool) -> String {
        if failed || rows.contains(where: { $0["status"] as? String == "failed" }) { return "failed" }
        return rows.allSatisfy { ["passed","not_applicable"].contains($0["status"] as? String ?? "") } ? "passed" : "incomplete"
    }
    static func adapter(profile: LabProfile, suite: String) -> [String:Any] {
        var row: [String:Any]=["profile":profile.rawValue,"suite":suite,"id":suite,"status":"not_run","adapter":true]
        if suite == "native" {
            let legacy="native-ddl-suite"
            row["declared_cases"]=DDLCoverageCases.registry.filter { $0.suite == legacy }.map { entry -> [String:Any] in
                var fields=entry.test.fields
                fields["variant_profiles"]=entry.profiles
                fields["group"]=entry.isGroup
                if let parent=entry.parent { fields["parent"]=parent }
                return fields
            }
        } else {
            row["inventory_granularity"]="suite; specialized runner owns individual assertions"
        }
        switch suite {
        case "native":
            row["intent"]="preserve existing assertions and evidence; includes bootstrap/version-specific experiments"
            if profile.sourceVersion == .mysql57 { row["status"]="not_applicable"; row["reason"]="Historical 8.4-source qualification; shared applicable workloads run in correctness." }
        case "recovery":
            row["intent"]=profile.transactionalTarget ? "transaction rollback, inspection and audited retry" : "MyISAM fail-stop and recovery refusal"
        default: break
        }
        return row
    }
    static func runAdapter(root: URL, profile: LabProfile, suite: String, build: Bool, onEvidence: @escaping (URL)->Void) throws {
        switch suite {
        case "recovery":
            try require(profile.transactionalTarget,"forward recovery must use the shared runner")
            try ReverseQualification.run(root:root,build:build,events:0,onEvidence:onEvidence)
        case "native": try NativeDDLQualification.run(root:root,onEvidence:onEvidence)
        default: throw LabError("unknown adapter suite")
        }
    }
    static func printJSON(_ value: Any) throws {
        print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
    }
}
