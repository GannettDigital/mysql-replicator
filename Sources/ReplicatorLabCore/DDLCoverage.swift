import Foundation

public enum DDLCoverage {
    struct Inventory {
        let catalog: DDLCatalog
        let profiles: DDLProfiles
        let upstream: DDLUpstream
    }

    static func safePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        try require(!path.isEmpty && !path.contains("\\") && !path.contains(":") && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) && path.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value != 127 }, "unsafe catalog relative path: \(path)")
    }
    private static func read(_ name: String, directory: URL) throws -> Data {
        try safePath(name)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = directory.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        try require(file.path.hasPrefix(root), "catalog path escapes its directory: \(name)")
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require(size <= 4 * 1024 * 1024, "catalog file exceeds 4 MiB: \(name)")
        return try Data(contentsOf: file)
    }
    private static func document<T: Decodable>(_ name: String, directory: URL, as type: T.Type) throws -> T {
        do {
            let data = try read(name + ".json", directory: directory)
            let schemaData = try read("schema/" + name + ".schema.json", directory: directory)
            guard let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else { throw LabError("schema must be an object") }
            try DDLCoverageSchema.validate(JSONSerialization.jsonObject(with: data), schema: schema)
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: data)
        } catch { throw LabError("\(name).json: \(error)") }
    }
    static func load(directory: URL, registry: [DDLCoverageCases.Entry] = DDLCoverageCases.registry) throws -> Inventory {
        let inventory = try Inventory(catalog: document("catalog", directory: directory, as: DDLCatalog.self),
                                      profiles: document("profiles", directory: directory, as: DDLProfiles.self),
                                      upstream: document("upstream", directory: directory, as: DDLUpstream.self))
        try validate(inventory, registry: registry)
        return inventory
    }
    private static func unique<T>(_ values: [T], _ id: (T) -> String, _ context: String) throws -> [String: T] {
        let ids = values.map(id)
        try require(Set(ids).count == ids.count, "duplicate \(context) ID")
        return Dictionary(uniqueKeysWithValues: zip(ids, values))
    }
    private static func outcome(_ outcome: DDLCatalog.Outcome, role: String, context: String) throws {
        let rejectionFields = outcome.errorNumber != nil || outcome.sqlstate != nil || outcome.diagnostic != nil
        switch outcome.outcome {
        case "success":
            try require(outcome.effect != nil && !rejectionFields, "\(context): success needs effect and cannot carry rejection fields")
        case "rejection":
            try require(outcome.effect == nil && (outcome.errorNumber != nil || outcome.diagnostic != nil), "\(context): rejection needs an error number or diagnostic and no success effect")
        default:
            try require(outcome.reason != nil && outcome.effect == nil && !rejectionFields, "\(context): unknown/not_applicable needs reason and no claimed effects/errors")
        }
        if role == "source" {
            try require(outcome.logging != nil, "\(context): source logging must be explicit")
        } else { try require(outcome.logging == nil, "\(context): logging belongs to the source outcome") }
    }
    static func validate(_ inventory: Inventory, registry: [DDLCoverageCases.Entry]) throws {
        let catalog = inventory.catalog
        try require(catalog.schemaVersion == 1 && inventory.profiles.schemaVersion == 1 && inventory.upstream.schemaVersion == 1, "unsupported DDL catalog schema version")
        let families = try unique(catalog.families, { $0.id }, "family")
        let features = try unique(catalog.features, { $0.id }, "feature")
        let scenarios = try unique(catalog.scenarios, { $0.id }, "scenario")
        let profiles = try unique(inventory.profiles.profiles, { $0.id }, "profile")
        let repos = try unique(inventory.upstream.repositories, { $0.id }, "upstream repository")
        let references = try unique(inventory.upstream.references, { $0.id }, "upstream reference")
        let cases = try unique(registry, { $0.key }, "registered case")
        _ = try unique(inventory.upstream.candidates, { $0.id }, "upstream candidate")
        try require(Set(families.keys) == Set(["A", "B", "C", "D", "E", "F"]), "catalog must retain families A–F")
        for family in catalog.families {
            for path in family.scanScope { try safePath(path) }
            try require(family.reviewState != "partial" || !family.outstandingQuestions.isEmpty, "\(family.id): partial inventory needs outstanding questions")
            try require(family.reviewState != "reviewed_for_declared_scope" || family.outstandingQuestions.isEmpty, "\(family.id): reviewed inventory has unresolved questions")
            try require(catalog.features.contains { $0.family == family.id }, "family without features: \(family.id)")
        }
        for feature in catalog.features {
            try require(families[feature.family] != nil, "unknown family for feature \(feature.id)")
            let actual = Set(catalog.scenarios.filter { $0.feature == feature.id }.map(\.id))
            try require(actual == Set(feature.scenarioIds), "\(feature.id): feature/scenario membership mismatch")
        }
        for repo in inventory.upstream.repositories { try safePath(repo.localPath) }
        for ref in inventory.upstream.references {
            try safePath(ref.path)
            try require(repos[ref.repository] != nil, "unknown repository for reference \(ref.id)")
            try require(ref.locator.endLine >= ref.locator.startLine, "invalid locator range for \(ref.id)")
            try require(!ref.dependenciesReviewed || ref.unresolvedDependencies.isEmpty, "\(ref.id): reviewed dependencies still unresolved")
            for id in ref.dependencies + ref.resultRefs {
                guard let dependency = references[id] else { throw LabError("dangling reference dependency: \(id)") }
                try require(dependency.repository == ref.repository, "cross-repository dependency: \(id)")
            }
            for id in ref.resultRefs { try require(references[id]?.kind == "result", "result reference has wrong kind: \(id)") }
        }
        for candidate in inventory.upstream.candidates {
            try safePath(candidate.path)
            try require(repos[candidate.repository] != nil && families[candidate.family] != nil, "invalid candidate repository/family: \(candidate.id)")
            for id in candidate.referenceIds { try require(references[id]?.repository == candidate.repository, "invalid candidate reference: \(id)") }
            for id in candidate.scenarioIds { try require(scenarios[id]?.family == candidate.family, "invalid candidate scenario: \(id)") }
            try require(candidate.state != "mapped" || !candidate.scenarioIds.isEmpty, "mapped candidate has no scenarios: \(candidate.id)")
            try require(candidate.state != "pending_review" || families[candidate.family]?.reviewState == "partial", "unreviewed candidate in completed inventory: \(candidate.id)")
        }
        for profile in inventory.profiles.profiles {
            let servers = try unique(profile.servers, { $0.role }, "server role in \(profile.id)")
            try require(Set(servers.keys) == Set(["source", "native84", "target57"]), "profile must declare all three servers: \(profile.id)")
            for server in profile.servers { _ = try unique(server.settings, { $0.name }, "setting in \(profile.id)/\(server.role)") }
            try require(registry.contains { $0.suite == profile.suite && $0.profiles.contains(profile.id) }, "profile is not supported by the case registry: \(profile.id)")
        }
        for entry in registry {
            try safePath(entry.test.file)
            for id in entry.profiles { try require(profiles[id]?.suite == entry.suite, "registry profile mismatch: \(entry.key)/\(id)") }
            if let parent = entry.parent { try require(cases[entry.suite + "/" + parent]?.isGroup == true, "missing registry parent: \(entry.key)") }
        }
        var bound = Set<String>()
        for scenario in catalog.scenarios {
            let context = scenario.id
            try require(features[scenario.feature]?.family == scenario.family, "\(context): feature/family mismatch")
            try require(scenario.scope != "excluded" || (!scenario.scopeReason.isEmpty && scenario.bindings.isEmpty), "\(context): excluded scenario needs a reason and no bindings")
            try require(!scenario.upstreamRefs.isEmpty || !scenario.gaps.isEmpty, "\(context): missing references must remain an explicit gap")
            _ = try unique(scenario.upstreamRefs, { $0.id }, "scenario reference in \(context)")
            for ref in scenario.upstreamRefs { try require(references[ref.id] != nil, "\(context): dangling upstream reference \(ref.id)") }
            let expectations = try unique(scenario.expectations, { $0.profile }, "expectation in \(context)")
            try require(Set(expectations.keys) == Set(scenario.requiredProfiles), "\(context): expectations must match required profiles exactly")
            let assertions = try unique(scenario.requiredAssertions, { $0.id }, "assertion in \(context)")
            for expectation in scenario.expectations {
                guard let profile = profiles[expectation.profile] else { throw LabError("\(context): unknown profile \(expectation.profile)") }
                for (role, expected) in [("source", expectation.source), ("native84", expectation.native84), ("target57_sql", expectation.target57Sql), ("swift57", expectation.swift57)] {
                    try outcome(expected, role: role, context: context + "/" + expectation.profile + "/" + role)
                }
                if profile.suite == "native-ddl-suite" { try require(expectation.swift57.outcome == "not_applicable", "\(context): native-only profile cannot qualify Swift") }
                if profile.suite == "ddl-suite" {
                    try require(expectation.target57Sql.outcome == "not_applicable", "\(context): Swift profile is not a direct-SQL qualification")
                    try require(scenario.intent != "apply" || !["rejection", "not_applicable"].contains(expectation.swift57.outcome), "\(context): apply intent contradicts Swift outcome")
                    try require(scenario.intent != "reject" || !["success", "not_applicable"].contains(expectation.swift57.outcome), "\(context): reject intent contradicts Swift outcome")
                }
                if expectation.source.logging == "no_event" { try require(["unknown", "not_applicable"].contains(expectation.native84.outcome) && ["unknown", "not_applicable"].contains(expectation.swift57.outcome), "\(context): no source event cannot prove replicated success or rejection") }
            }
            for binding in scenario.bindings {
                try require(Set(binding.profiles).isSubset(of: Set(scenario.requiredProfiles)), "\(context): binding has an inapplicable profile")
                try require(Set(binding.assertionIds).isSubset(of: Set(assertions.keys)), "\(context): binding claims undeclared assertions")
                try require(binding.assertionIds.isEmpty, "\(context): named assertion bindings await evidence integration")
                try require(binding.role == (binding.suite == "ddl-suite" ? "swift_apply_with_native_reference" : "native_observation_and_direct_sql"), "\(context): binding role/suite mismatch")
                for profile in binding.profiles { try require(profiles[profile]?.suite == binding.suite, "\(context): binding suite/profile mismatch") }
                for id in binding.caseIds + [binding.completionCaseId].compactMap({ $0 }) {
                    let key = binding.suite + "/" + id
                    guard let entry = cases[key] else { throw LabError("\(context): dangling case binding \(key)") }
                    try require(Set(binding.profiles).isSubset(of: Set(entry.profiles)), "\(context): case does not run in the required profile")
                    bound.insert(key)
                }
                for id in binding.caseIds {
                    let entry = cases[binding.suite + "/" + id]!
                    if let parent = entry.parent { try require(binding.completionCaseId == parent, "\(context): child binding lacks its completion group") }
                }
                if let completion = binding.completionCaseId { try require(cases[binding.suite + "/" + completion]?.isGroup == true, "\(context): completion case is not a group") }
                let children = binding.caseIds.compactMap { id in registry.firstIndex { $0.suite == binding.suite && $0.test.id == id && $0.parent != nil } }
                try require(children == children.sorted(), "\(context): ordered child cases are out of execution order")
            }
            if scenario.implementation == "implemented" && scenario.intent != "observe" {
                try require(scenario.bindings.contains { $0.suite == "ddl-suite" }, "\(context): implemented Swift behavior needs a binding")
            }
        }
        let classifications = try unique(catalog.caseClassifications, { $0.suite + "/" + $0.caseId }, "case classification")
        for key in classifications.keys { try require(cases[key] != nil && !bound.contains(key), "invalid or overlapping non-catalog classification: \(key)") }
        try require(bound.union(classifications.keys) == Set(cases.keys), "unmapped registered cases: \(Set(cases.keys).subtracting(bound).subtracting(classifications.keys).sorted())")
    }

    private static func outcomeFields(_ outcome: DDLCatalog.Outcome) -> [String: Any] {
        var fields: [String: Any] = ["outcome": outcome.outcome, "warnings": outcome.warnings, "partial_effects": outcome.partialEffects]
        fields["effect"] = outcome.effect; fields["logging"] = outcome.logging; fields["reason"] = outcome.reason
        fields["error_number"] = outcome.errorNumber; fields["sqlstate"] = outcome.sqlstate; fields["diagnostic"] = outcome.diagnostic
        return fields
    }
    static func report(_ inventory: Inventory) -> [String: Any] {
        let catalog = inventory.catalog
        let rows: [[String: Any]] = catalog.scenarios.sorted { $0.id < $1.id }.map { scenario in
            ["id": scenario.id, "name": scenario.name, "family": scenario.family, "feature": scenario.feature,
             "scope": scenario.scope, "implementation": scenario.implementation, "intent": scenario.intent,
             "qualification": scenario.scope == "excluded" ? "excluded" : "unverified",
             "profiles": scenario.requiredProfiles.sorted(), "gaps": scenario.gaps,
             "expected_outcomes": scenario.expectations.sorted { $0.profile < $1.profile }.map { expected -> [String: Any] in
                 ["profile": expected.profile, "source": outcomeFields(expected.source), "native84": outcomeFields(expected.native84),
                  "target57_sql": outcomeFields(expected.target57Sql), "swift57": outcomeFields(expected.swift57)]
             },
             "required_assertions": scenario.requiredAssertions.map { ["id": $0.id, "description": $0.description] },
             "bindings": scenario.bindings.map { binding -> [String: Any] in
                ["suite": binding.suite, "case_ids": binding.caseIds, "completion_case_id": binding.completionCaseId as Any? ?? NSNull(),
                 "profiles": binding.profiles.sorted(), "assertion_ids": binding.assertionIds.sorted()]
             }]
        }
        let families: [[String: Any]] = catalog.families.sorted { $0.id < $1.id }.map { family in
            let scoped = catalog.scenarios.filter { $0.family == family.id }
            return ["id": family.id, "name": family.name, "inventory_review": family.reviewState,
                    "scenarios": scoped.count, "implemented": scoped.filter { $0.implementation == "implemented" }.count,
                    "implemented_applies": scoped.filter { $0.implementation == "implemented" && $0.intent == "apply" }.count,
                    "implemented_rejections": scoped.filter { $0.implementation == "implemented" && $0.intent == "reject" }.count,
                    "implemented_observations": scoped.filter { $0.implementation == "implemented" && $0.intent == "observe" }.count,
                    "in_scope": scoped.filter { $0.scope == "in_scope" }.count,
                    "profile_obligations": scoped.filter { $0.scope == "in_scope" }.reduce(0) { $0 + $1.requiredProfiles.count },
                    "verified_applies": 0, "verified_rejections": 0, "outstanding_questions": family.outstandingQuestions]
        }
        return ["schema_version": 1, "inventory_revision": catalog.inventoryRevision,
                "evidence_status": "not_loaded", "qualification_note": "Offline inventory only. Assertion evidence and provenance verification are not implemented; no scenario is promoted from an aggregate suite pass.",
                "families": families, "scenarios": rows,
                "registered_cases": DDLCoverageCases.registry.sorted { $0.key < $1.key }.map { entry -> [String: Any] in
                    var fields = entry.test.fields; fields["suite"] = entry.suite; fields["profiles"] = entry.profiles; return fields
                }, "non_catalog_cases": catalog.caseClassifications.map { ["suite": $0.suite, "case_id": $0.caseId, "reason": $0.reason] }]
    }
    static func markdown(_ inventory: Inventory) -> String {
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        var lines = ["# DDL coverage inventory", "", "Inventory: `\(inventory.catalog.inventoryRevision)`. No evidence loaded; all in-scope obligations are unverified.", "", "Implementation is not qualification. Upstream inventory remains partial; counts describe this catalog, not all MySQL DDL.", "", "| Family | Inventory review | Scenarios | Profile obligations |", "| --- | --- | ---: | ---: |"]
        for family in inventory.catalog.families.sorted(by: { $0.id < $1.id }) {
            let scenarios = inventory.catalog.scenarios.filter { $0.family == family.id }
            lines.append("| \(family.id): \(cell(family.name)) | \(family.reviewState) | \(scenarios.count) | \(scenarios.filter { $0.scope == "in_scope" }.reduce(0) { $0 + $1.requiredProfiles.count }) |")
        }
        lines += ["", "| Scenario | Behavior | Implementation | Intent | Qualification | Profiles | Cases |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for scenario in inventory.catalog.scenarios.sorted(by: { $0.id < $1.id }) {
            let bindings = scenario.bindings.map { $0.suite + ": " + $0.caseIds.joined(separator: ", ") }.joined(separator: "; ")
            lines.append("| \(scenario.id) | \(cell(scenario.name)) | \(scenario.implementation) | \(scenario.intent) | \(scenario.scope == "excluded" ? "excluded" : "unverified") | \(scenario.requiredProfiles.joined(separator: ", ")) | \(cell(bindings)) |")
        }
        lines += ["", "## Expected outcomes by profile", "", "These are scenario contracts, not observed or verified results.", "", "| Scenario / profile | Source | Native 8.4 | Direct SQL 5.7 | Swift 5.7 |", "| --- | --- | --- | --- | --- |"]
        func expectedText(_ outcome: DDLCatalog.Outcome) -> String {
            var text = outcome.outcome
            if let effect = outcome.effect { text += ": " + effect }
            if let logging = outcome.logging { text += "; log=" + logging }
            if let error = outcome.errorNumber { text += "; error=\(error)" }
            if let diagnostic = outcome.diagnostic { text += "; " + diagnostic }
            return cell(text)
        }
        for scenario in inventory.catalog.scenarios.sorted(by: { $0.id < $1.id }) {
            for expected in scenario.expectations.sorted(by: { $0.profile < $1.profile }) {
                lines.append("| \(scenario.id) / \(expected.profile) | \(expectedText(expected.source)) | \(expectedText(expected.native84)) | \(expectedText(expected.target57Sql)) | \(expectedText(expected.swift57)) |")
            }
        }
        lines += ["", "See catalog.json for prerequisites, required assertions, references and outstanding gaps."]
        return lines.joined(separator: "\n") + "\n"
    }
    public static func run(root: URL, arguments: [String]) throws {
        guard let command = arguments.first, ["check", "report", "scan", "upstream-check"].contains(command) else { throw LabError("ddl-catalog supports check, report, scan and upstream-check; evidence and verify remain planned") }
        if ["scan", "upstream-check"].contains(command) {
            let inventory = try load(directory: root.appendingPathComponent("tests/DDLCoverage"))
            return try DDLUpstreamInspection.run(root: root, command: command, options: Array(arguments.dropFirst()), inventory: inventory)
        }
        let options = Array(arguments.dropFirst())
        var format = "markdown"
        if command == "check" { try require(options.isEmpty, "ddl-catalog check accepts no arguments") }
        else if !options.isEmpty {
            try require(options.count == 2 && options[0] == "--format" && ["markdown", "json"].contains(options[1]), "ddl-catalog report accepts only --format markdown|json; evidence import is not implemented")
            format = options[1]
        }
        let inventory = try load(directory: root.appendingPathComponent("tests/DDLCoverage"))
        if command == "check" {
            // Exercise both deterministic renderers without creating artifacts.
            _ = markdown(inventory)
            _ = try JSONSerialization.data(withJSONObject: report(inventory), options: [.prettyPrinted, .sortedKeys])
            print("PASS DDL catalog structure: \(inventory.catalog.scenarios.count) scenarios, \(DDLCoverageCases.registry.count) registered cases. No replication coverage qualified.")
        } else if format == "json" {
            let data = try JSONSerialization.data(withJSONObject: report(inventory), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } else { print(markdown(inventory), terminator: "") }
    }
}
