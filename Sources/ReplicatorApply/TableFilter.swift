import Foundation
import ReplicatorCodec

/// MySQL wild-ignore patterns match the complete database.table name. The
/// qualified Linux target uses lower_case_table_names=0 (case-sensitive).
struct TableFilter {
    let patterns: [String]
    init(_ patterns: [String] = []) throws {
        try require(patterns.count <= 128, "too many replicateWildIgnoreTable patterns (maximum 128)")
        for pattern in patterns {
            try require(!pattern.isEmpty && pattern.utf8.count <= 512 && pattern.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value != 127 }, "invalid replicateWildIgnoreTable pattern")
            let parts = pattern.split(separator: ".", omittingEmptySubsequences: false)
            try require(parts.count == 2 && parts.allSatisfy { !$0.isEmpty }, "replicateWildIgnoreTable requires database.table patterns")
            var escaped = false
            for c in pattern { if escaped { escaped = false } else if c == "\\" { escaped = true } }
            try require(!escaped, "trailing escape in replicateWildIgnoreTable pattern")
        }
        self.patterns = patterns
    }
    func ignores(database: String, table: String) -> Bool {
        patterns.contains { Self.matches($0, database + "." + table) }
    }
    // Native db_ok_with_wild_table matches "database." (empty table name).
    func ignores(database: String) -> Bool { ignores(database: database, table: "") }
    static func matches(_ pattern: String, _ value: String) -> Bool {
        let input = Array(value.unicodeScalars), p = Array(pattern.unicodeScalars)
        var previous = [Bool](repeating: false, count: input.count + 1); previous[0] = true
        var i = 0
        while i < p.count {
            var token = p[i]; i += 1
            let escaped = token == "\\" && i < p.count
            if escaped { token = p[i]; i += 1 }
            var next = [Bool](repeating: false, count: input.count + 1)
            if token == "%" && !escaped {
                next[0] = previous[0]
                for j in input.indices { next[j+1] = previous[j+1] || next[j] }
            } else {
                for j in input.indices { next[j+1] = previous[j] && ((!escaped && token == "_") || token == input[j]) }
            }
            previous = next
        }
        return previous[input.count]
    }
    func ignores(_ query: QueryControl) throws -> Bool {
        try DDLPolicy.rejectProhibited(query)
        // Stored-program bodies may contain semicolons. Classify their header
        // before the scope-only table lexer; trigger/event policy is unconditional.
        var objects = try DDLParser(query.sql,database:query.database,sqlMode:query.statusVariables.isEmpty ? 0 : QuerySessionContext(query:query).sqlMode)
        if let statement = try objects.objectStatement(), case .object(let object) = statement {
            return object.kind == .view ? ignores(database:object.name.database,table:object.name.table) : ignores(database:object.name.database)
        }
        guard !patterns.isEmpty else { return false }
        if objects.take("DROP"), objects.take("DATABASE") || objects.take("SCHEMA") {
            if objects.take("IF") { try objects.expect("EXISTS") }
            let database = try objects.identifier()
            let partial = patterns.contains { pattern in
                Self.matches(String(pattern.split(separator:".")[0]),database)
            } && !ignores(database:database)
            try require(!partial,"DROP DATABASE crosses included and excluded tables; explicit resolution required")
        }
        try require(query.errorCode == 0, "filtered DDL source query reported an error")
        var scope = try FilterSQL(query)
        guard let targets = try scope.targets() else { return false }
        let decisions = targets.map { target in
            target.table.map { ignores(database: target.database, table: $0) } ?? ignores(database: target.database)
        }
        // Cross-boundary multi-object DDL needs operation-specific native
        // qualification. Never execute a statement that could mutate exclusions.
        try require(decisions.allSatisfy { $0 } || decisions.allSatisfy { !$0 }, "DDL crosses included and excluded tables; explicit resolution required")
        return !decisions.isEmpty && decisions.allSatisfy { $0 }
    }
}

/// Scope-only lexer. It does not qualify SQL for target execution: included
/// queries still go through DDLStatement. Excluded column types/engines need no
/// schema model. Unknown SQL, executable comments and ambiguous syntax fail closed.
private struct FilterSQL {
    struct Token { let text: String; let quoted: Bool }
    struct Target { let database: String; let table: String? }
    var tokens: [Token] = []
    var i = 0
    let database: String?
    init(_ query: QueryControl) throws {
        database = query.database
        try require(query.sql.count <= 65536, "DDL statement exceeds 64 KiB")
        let b = Array(query.sql); var j = 0
        while j < b.count {
            let c = b[j]
            if [9,10,13,32].contains(c) { j += 1; continue }
            if c == 35 || (c == 45 && j+2 < b.count && b[j+1] == 45 && b[j+2] <= 32) {
                while j < b.count && b[j] != 10 { j += 1 }; continue
            }
            if c == 47 && j+1 < b.count && b[j+1] == 42 {
                try require(j+2 < b.count && b[j+2] != 33, "cannot filter executable SQL comments")
                j += 2
                while j+1 < b.count && !(b[j] == 42 && b[j+1] == 47) { j += 1 }
                try require(j+1 < b.count, "unterminated SQL comment"); j += 2; continue
            }
            if c == 96 || c == 39 {
                let quote = c; j += 1; var bytes: [UInt8] = []; var closed = false
                while j < b.count {
                    if b[j] == quote {
                        if j+1 < b.count && b[j+1] == quote { bytes.append(quote); j += 2; continue }
                        j += 1; closed = true; break
                    }
                    // Backslash literal semantics depend on SQL mode. Decline
                    // scope filtering rather than misclassify the following SQL.
                    try require(b[j] != 92, "cannot filter SQL with ambiguous backslash quoting")
                    bytes.append(b[j]); j += 1
                }
                try require(closed, "unterminated SQL quote")
                guard let text = String(bytes: bytes, encoding: .utf8) else { throw ApplyError("invalid SQL identifier encoding") }
                tokens.append(Token(text: quote == 96 ? text : "<literal>", quoted: true))
            } else if (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 || c == 36 {
                let start = j; j += 1
                while j < b.count && ((65...90).contains(b[j]) || (97...122).contains(b[j]) || (48...57).contains(b[j]) || b[j] == 95 || b[j] == 36) { j += 1 }
                tokens.append(Token(text: String(decoding: b[start..<j], as: UTF8.self), quoted: false))
            } else {
                try require(c != 34 && c < 128, "unsupported filter SQL quoting/identifier")
                tokens.append(Token(text: String(UnicodeScalar(c)), quoted: false)); j += 1
            }
        }
        if tokens.last?.text == ";" { tokens.removeLast() }
        try require(!tokens.contains { !$0.quoted && $0.text == ";" }, "multiple statements in filtered query")
    }
    mutating func take(_ word: String) -> Bool {
        guard i < tokens.count, !tokens[i].quoted, tokens[i].text.uppercased() == word else { return false }
        i += 1; return true
    }
    mutating func identifier() throws -> String {
        try require(i < tokens.count, "missing filter DDL identifier")
        let t = tokens[i]; i += 1
        try require(t.text != "<literal>" && (t.quoted || t.text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 36 }), "invalid filter DDL identifier")
        return t.text
    }
    mutating func name() throws -> Target {
        let first = try identifier()
        if take(".") { return Target(database: first, table: try identifier()) }
        guard let database, !database.isEmpty else { throw ApplyError("unqualified filter DDL without database") }
        return Target(database: database, table: first)
    }
    mutating func conditional() throws {
        if take("IF") { _ = take("NOT"); try require(take("EXISTS"), "invalid conditional DDL") }
    }
    mutating func targets() throws -> [Target]? {
        if take("RENAME") {
            guard take("TABLE") else { return nil }
            var names: [Target] = []
            repeat { names.append(try name()); try require(take("TO"), "invalid RENAME filter scope"); names.append(try name()) } while take(",")
            try require(i == tokens.count, "unknown RENAME filter scope"); return names
        }
        guard i < tokens.count else { return nil }
        let verb = tokens[i].text.uppercased(); i += 1
        guard ["CREATE", "ALTER", "DROP", "TRUNCATE"].contains(verb) else { return nil }
        if take("DATABASE") || take("SCHEMA") {
            try conditional(); return [Target(database: try identifier(), table: nil)]
        }
        _ = take("UNIQUE"); _ = take("FULLTEXT"); _ = take("SPATIAL")
        if take("INDEX") {
            _ = try identifier()
            if take("USING") { _ = try identifier() }
            try require(take("ON"), "invalid index filter scope"); return [try name()]
        }
        _ = take("TEMPORARY")
        guard take("TABLE") || take("VIEW") || verb == "TRUNCATE" else { return nil }
        try conditional(); var names = [try name()]
        if verb == "DROP" {
            while take(",") { names.append(try name()) }
            _ = take("RESTRICT"); _ = take("CASCADE")
            try require(i == tokens.count, "unknown DROP filter scope")
        }
        if verb == "ALTER" {
            while i < tokens.count {
                if take("EXCHANGE") {
                    try require(take("PARTITION"),"invalid EXCHANGE filter scope"); _ = try identifier()
                    try require(take("WITH") && take("TABLE"),"invalid EXCHANGE filter scope"); names.append(try name())
                }
                else if take("RENAME") {
                    if take("INDEX") || take("KEY") || take("COLUMN") { continue }
                    _ = take("TO"); _ = take("AS"); names.append(try name())
                } else { i += 1 }
            }
        }
        return names
    }
}
