import Foundation

struct DDLCatalog: Decodable {
    let schemaVersion: Int
    let inventoryRevision: String
    let families: [Family]
    let features: [Feature]
    let scenarios: [Scenario]
    let caseClassifications: [Classification]
    struct Family: Decodable {
        let id, name, reviewState: String
        let scanScope, outstandingQuestions: [String]
    }
    struct Feature: Decodable {
        let id, family, name, grammar: String
        let scenarioIds: [String]
    }
    struct Reference: Decodable { let id, relationship, note: String }
    struct Assertion: Decodable { let id, description: String }
    struct Binding: Decodable {
        let suite, role, note: String
        let caseIds, profiles, assertionIds: [String]
        let producers: [String]?
        var acceptedProducers: [String] { producers ?? ["legacy"] }
        let completionCaseId: String?
    }
    struct Outcome: Decodable {
        let outcome, warnings, partialEffects: String
        let effect, logging, reason, sqlstate, diagnostic: String?
        let errorNumber: Int?
    }
    struct Expectation: Decodable {
        let profile: String
        let source, native84, target57Sql, swift57: Outcome
    }
    struct Scenario: Decodable {
        let id, name, family, feature, scope, scopeReason, implementation, intent: String
        let prerequisites, operation, followingWorkload: [String]
        let upstreamRefs: [Reference]
        let requiredProfiles: [String]
        let expectations: [Expectation]
        let requiredAssertions: [Assertion]
        let bindings: [Binding]
        let gaps: [String]
    }
    struct Classification: Decodable { let suite, caseId, reason: String }
}

struct DDLProfiles: Decodable {
    let schemaVersion: Int
    let profiles: [Profile]
    struct Setting: Decodable { let name, value, basis: String }
    struct Server: Decodable {
        let role, version, imageReference: String
        let settings: [Setting]
        let unresolved: [String]
    }
    struct Profile: Decodable {
        let id, suite, description, positioning, rowMetadata, rowImage: String
        let servers: [Server]
        let unresolved: [String]
    }
}

struct DDLUpstream: Decodable {
    let schemaVersion: Int
    let repositories: [Repository]
    let references: [Reference]
    let candidates: [Candidate]
    struct Repository: Decodable { let id, url, revision, localPath: String }
    struct Locator: Decodable { let anchor: String; let startLine, endLine: Int }
    struct Reference: Decodable {
        let id, repository, path, kind, sha256: String
        let locator: Locator
        let dependencies, resultRefs, unresolvedDependencies: [String]
        let dependenciesReviewed: Bool
    }
    struct Candidate: Decodable {
        let id, repository, path, family, state, reason: String
        let referenceIds, scenarioIds: [String]
    }
}
