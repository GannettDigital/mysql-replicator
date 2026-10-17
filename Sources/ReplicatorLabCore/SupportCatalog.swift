import Foundation

/// Support requirements extend the DDL inventory. Candidate tests are pointers,
/// not assertion bindings and never proof of qualification.
struct SupportCatalog: Decodable {
    let schemaVersion: Int
    let inventoryRevision: String
    let reviewState: String
    let requirements: [Requirement]

    struct Requirement: Decodable {
        let id, family, classification, eligibility, implementation: String
        let stage: Int
        let profiles, variants, conditions: [String]
        let sourceBehavior, nativeBehavior, currentBehavior, acceptance: String
        let assertions, candidateCases, codeReferences: [String]
        let nativeReferences: [Reference]
        struct Reference: Decodable { let repository, path, symbol: String }
    }

    func validate(upstream: DDLUpstream, scenarios: [LabScenario] = LabScenario.correctness) throws {
        try require(schemaVersion == 1 && reviewState == "partial", "unsupported support catalog version/review state")
        try require(Set(requirements.map(\.id)).count == requirements.count, "duplicate support requirement ID")
        let repositories = Set(upstream.repositories.map(\.id))
        let cases = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id,$0) })
        for item in requirements {
            let context = "support requirement " + item.id + ": "
            try require(item.implementation != "not_applicable" || item.eligibility == "excluded",context + "implementation gaps cannot be marked not applicable")
            try require(Set(item.profiles).count == item.profiles.count && Set(item.variants).count == item.variants.count,
                        context + "duplicate profile or variant")
            for profileID in item.profiles {
                guard let profile = LabProfile(rawValue:profileID) else { throw LabError(context + "unknown profile " + profileID) }
                for variantID in item.variants {
                    guard let variant = LabVariant(rawValue:variantID), variant.reason(profile) == nil else {
                        throw LabError(context + "unsupported profile/variant " + profileID + "/" + variantID)
                    }
                }
            }
            if ["native_restriction","target_limit","safety_policy"].contains(item.classification) {
                try require(item.eligibility == "excluded", context + "restriction/policy cannot count as positive support")
            } else {
                try require(item.eligibility != "excluded", context + "tool gaps cannot be hidden as exclusions")
            }
            if item.classification == "native_restriction" || item.classification == "target_limit" {
                try require(!item.nativeReferences.isEmpty, context + "native/target restriction needs a pinned source reference")
            }
            for reference in item.nativeReferences {
                try require(repositories.contains(reference.repository), context + "unknown upstream repository")
                try DDLCoverage.safePath(reference.path)
            }
            for path in item.codeReferences { try DDLCoverage.safePath(path) }
            for id in item.candidateCases {
                guard let scenario = cases[id] else { throw LabError(context + "unknown candidate case " + id) }
                try require(item.profiles.contains { profile in item.variants.contains { variant in
                    scenario.reason(LabProfile(rawValue:profile)!,variant:LabVariant(rawValue:variant)!) == nil
                } }, context + "candidate case is not applicable: " + id)
            }
        }
    }

    func report(upstream: DDLUpstream) -> [String:Any] {
        let rows: [[String:Any]] = requirements.sorted { $0.id < $1.id }.map { item in
            ["id":item.id,"family":item.family,"stage":item.stage,"classification":item.classification,
             "positive_support_eligibility":item.eligibility,"implementation":item.implementation,
             "qualification":"unverified","profiles":item.profiles,"variants":item.variants,
             "conditions":item.conditions,"source_behavior":item.sourceBehavior,"native_behavior":item.nativeBehavior,
             "current_behavior":item.currentBehavior,"acceptance":item.acceptance,"required_assertions":item.assertions,
             "candidate_cases":item.candidateCases,"code_references":item.codeReferences,
             "native_references":item.nativeReferences.map { ["repository":$0.repository,"path":$0.path,"symbol":$0.symbol] }]
        }
        return ["inventory_revision":inventoryRevision,"review_state":reviewState,"requirements":rows,
                "upstream_repositories":upstream.repositories.map { ["id":$0.id,"url":$0.url,"revision":$0.revision] },
                "qualification_note":"Candidate cases are not assertion evidence. No requirement is qualified by this inventory or by DDL evidence import.",
                "summary":["requirements":requirements.count,
                           "eligible":requirements.filter { $0.eligibility == "eligible" }.count,
                           "needs_native_review":requirements.filter { $0.eligibility == "needs_native_review" }.count,
                           "excluded":requirements.filter { $0.eligibility == "excluded" }.count,
                           "qualified":0]]
    }

    var markdown: String {
        var lines = ["", "## Support requirements", "", "Partial inventory. All requirements are unverified. Candidate cases are not qualification evidence.", "",
                     "| Requirement | Stage | Classification | Positive support | Implementation |", "| --- | ---: | --- | --- | --- |"]
        for item in requirements.sorted(by: { $0.id < $1.id }) {
            lines.append("| \(item.id) | \(item.stage) | \(item.classification) | \(item.eligibility) | \(item.implementation) |")
        }
        lines += ["", "See support.json for profile conditions, required assertions, source references, and candidate tests.", ""]
        return lines.joined(separator:"\n")
    }
}
