import Foundation
import ReplicatorCodec

/// MySQL wild-ignore patterns match the complete database.table name. The
/// configured server setting selects exact or native lowercase comparison.
struct TableFilter {
    let patterns: [String]
    let includes: [String]
    var isEmpty: Bool { patterns.isEmpty && includes.isEmpty }
    let lowerCaseTableNames: Int
    init(_ patterns: [String] = [], including includes: [String] = [], lowerCaseTableNames: Int = 0) throws {
        try require([0, 1].contains(lowerCaseTableNames), "unsupported table-name case setting")
        self.lowerCaseTableNames = lowerCaseTableNames
        self.includes = includes
        try require(includes.count <= 128, "too many replicateWildDoTable patterns (maximum 128)")
        try require(patterns.count <= 128, "too many replicateWildIgnoreTable patterns (maximum 128)")
        for pattern in patterns + includes {
            try require(
                !pattern.isEmpty && pattern.utf8.count <= 512
                    && pattern.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value <= 0xffff && $0.value != 127 },
                "invalid replication table pattern")
            let parts = pattern.split(separator: ".", omittingEmptySubsequences: false)
            try require(
                parts.count == 2 && parts.allSatisfy { !$0.isEmpty },
                "replication filters require database.table patterns")
            var escaped = false
            for c in pattern { if escaped { escaped = false } else if c == "\\" { escaped = true } }
            try require(!escaped, "trailing escape in replication table pattern")
        }
        self.patterns = patterns
    }
    private func matches(_ pattern: String, _ value: String) -> Bool {
        Self.matches(
            lowerCaseTableNames == 1 ? SQLIdentifier.lowercase(pattern) : pattern,
            lowerCaseTableNames == 1 ? SQLIdentifier.lowercase(value) : value)
    }
    func ignores(database: String, table: String) -> Bool {
        let name = database + "." + table
        if includes.contains(where: { matches($0, name) }) { return false }
        if patterns.contains(where: { matches($0, name) }) { return true }
        return !includes.isEmpty
    }
    // Native db_ok_with_wild_table matches "database." (empty table name).
    func ignores(database: String) -> Bool { ignores(database: database, table: "") }
    static func matches(_ pattern: String, _ value: String) -> Bool {
        let input = Array(value.unicodeScalars)
        let p = Array(pattern.unicodeScalars)
        var previous = [Bool](repeating: false, count: input.count + 1)
        previous[0] = true
        var i = 0
        while i < p.count {
            var token = p[i]
            i += 1
            let escaped = token == "\\" && i < p.count
            if escaped {
                token = p[i]
                i += 1
            }
            var next = [Bool](repeating: false, count: input.count + 1)
            if token == "%" && !escaped {
                next[0] = previous[0]
                for j in input.indices { next[j + 1] = previous[j + 1] || next[j] }
            } else {
                for j in input.indices {
                    next[j + 1] = previous[j] && ((!escaped && token == "_") || token == input[j])
                }
            }
            previous = next
        }
        return previous[input.count]
    }
    func ignores(_ query: QueryControl, tokens: [DDLToken]? = nil) throws -> Bool {
        try DDLPolicy.rejectProhibited(query)
        try require(
            query.errorCode == 0,
            "filtered DDL source query reported an error: source error code \(query.errorCode); partial source DDL is not supported"
        )
        // Stored-program bodies may contain semicolons. Classify their header
        // before the scope-only table lexer; trigger/event policy is unconditional.
        var objects = try DDLParser(query: query, tokens: tokens)
        if let statement = try objects.objectStatement(), case .object(let object) = statement {
            if object.kind != .view { return ignores(database: object.name.database) }
            let decisions = object.names.map { ignores(database: $0.database, table: $0.table) }
            try require(
                decisions.allSatisfy { $0 } || decisions.allSatisfy { !$0 },
                "DDL crosses included and excluded tables; explicit resolution required")
            return decisions.allSatisfy { $0 }
        }
        guard !isEmpty, !objects.tokens.isEmpty else { return false }
        if objects.take("DROP"), objects.take("DATABASE") || objects.take("SCHEMA") {
            if objects.take("IF") { try objects.expect("EXISTS") }
            let database = try objects.identifier()
            let includesDatabase = includes.contains { matches($0, database + ".") }
            let partialInclude =
                !includesDatabase && includes.contains { matches(String($0.split(separator: ".")[0]), database) }
            let partial =
                !includesDatabase
                && patterns.contains { pattern in
                    matches(String(pattern.split(separator: ".")[0]), database)
                } && !ignores(database: database)
            try require(
                !partial && !partialInclude,
                "DROP DATABASE crosses included and excluded tables; explicit resolution required")
        }
        var scope = try FilterSQL(query, tokens: tokens)
        guard let targets = try scope.targets() else { return false }
        let decisions = targets.map { target in
            target.table.map { ignores(database: target.database, table: $0) } ?? ignores(database: target.database)
        }
        // Cross-boundary multi-object DDL needs operation-specific native
        // qualification. Never execute a statement that could mutate exclusions.
        try require(
            decisions.allSatisfy { $0 } || decisions.allSatisfy { !$0 },
            "DDL crosses included and excluded tables; explicit resolution required")
        return !decisions.isEmpty && decisions.allSatisfy { $0 }
    }
}

/// Scope-only lexer. It does not qualify SQL for target execution: included
/// queries still go through DDLStatement. Excluded column types/engines need no
/// schema model. Unknown SQL and ambiguous syntax fail closed. Tokens use target version gates.
private struct FilterSQL {
    struct Token {
        let text: String
        let quoted: Bool
    }
    struct Target {
        let database: String
        let table: String?
    }
    var tokens: [Token] = []
    var i = 0
    let database: String?
    init(_ query: QueryControl, tokens parsed: [DDLToken]? = nil) throws {
        database = query.database
        let parsed = try parsed ?? DDLParser(query: query).tokens
        tokens = parsed.map {
            Token(text: $0.literal == nil ? $0.text : "<literal>", quoted: $0.identifier || $0.literal != nil)
        }
        if tokens.last?.text == ";", tokens.last?.quoted == false { tokens.removeLast() }
        try require(!tokens.contains { !$0.quoted && $0.text == ";" }, "multiple statements in filtered query")
    }
    mutating func take(_ word: String) -> Bool {
        guard i < tokens.count, !tokens[i].quoted, SQLIdentifier.keyword(tokens[i].text) == word else { return false }
        i += 1
        return true
    }
    mutating func identifier() throws -> String {
        try require(i < tokens.count, "missing filter DDL identifier")
        let t = tokens[i]
        i += 1
        try require(
            t.text != "<literal>" && (t.quoted || t.text.utf8.allSatisfy(DDLTokens.word)),
            "invalid filter DDL identifier")
        return t.text
    }
    mutating func name() throws -> Target {
        let first = try identifier()
        if take(".") { return Target(database: first, table: try identifier()) }
        guard let database, !database.isEmpty else { throw ApplyError("unqualified filter DDL without database") }
        return Target(database: database, table: first)
    }
    mutating func conditional() throws {
        if take("IF") {
            _ = take("NOT")
            try require(take("EXISTS"), "invalid conditional DDL")
        }
    }
    mutating func targets() throws -> [Target]? {
        if take("RENAME") {
            guard take("TABLE") else { return nil }
            var names: [Target] = []
            repeat {
                names.append(try name())
                try require(take("TO"), "invalid RENAME filter scope")
                names.append(try name())
            } while take(",")
            try require(i == tokens.count, "unknown RENAME filter scope")
            return names
        }
        guard i < tokens.count else { return nil }
        let verb = SQLIdentifier.keyword(tokens[i].text)
        i += 1
        guard ["CREATE", "ALTER", "DROP", "TRUNCATE"].contains(verb) else { return nil }
        if take("DATABASE") || take("SCHEMA") {
            try conditional()
            return [Target(database: try identifier(), table: nil)]
        }
        _ = take("UNIQUE")
        _ = take("FULLTEXT")
        _ = take("SPATIAL")
        if take("INDEX") {
            _ = try identifier()
            if take("USING") { _ = try identifier() }
            try require(take("ON"), "invalid index filter scope")
            return [try name()]
        }
        _ = take("TEMPORARY")
        guard take("TABLE") || take("VIEW") || verb == "TRUNCATE" else { return nil }
        try conditional()
        var names = [try name()]
        if verb == "DROP" {
            while take(",") { names.append(try name()) }
            _ = take("RESTRICT")
            _ = take("CASCADE")
            try require(i == tokens.count, "unknown DROP filter scope")
        }
        if verb == "ALTER" {
            while i < tokens.count {
                if take("EXCHANGE") {
                    try require(take("PARTITION"), "invalid EXCHANGE filter scope")
                    _ = try identifier()
                    try require(take("WITH") && take("TABLE"), "invalid EXCHANGE filter scope")
                    names.append(try name())
                } else if take("RENAME") {
                    if take("INDEX") || take("KEY") || take("COLUMN") { continue }
                    _ = take("TO")
                    _ = take("AS")
                    names.append(try name())
                } else {
                    i += 1
                }
            }
        }
        // Even a skipped child DDL must not introduce a relationship to an
        // included parent: its future cascades are not separate row events.
        i = 0
        while i < tokens.count {
            if take("REFERENCES") {
                let first = try identifier()
                names.append(
                    take(".")
                        ? Target(database: first, table: try identifier())
                        : Target(database: names[0].database, table: first))
            } else {
                i += 1
            }
        }
        return names
    }
}

extension ApplyConfiguration {
    func filterIdentity() throws -> String {
        String(
            decoding: try JSONEncoder().encode([
                (replicateWildDoTable ?? []).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
                (replicateWildIgnoreTable ?? []).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
            ]), as: UTF8.self)
    }
}
