import Foundation
import MySQLNIO
import MySQLSyntax
import ReplicatorCodec

/// MySQL stores evaluated partition bounds, while the Query event retains SQL.
/// Use the target's constant evaluator before the DDL intent is saved. Never
/// evaluate column references, stored functions, variables or subqueries here.
enum PartitionBounds {
    static let functions: Set<String> = [
        "abs", "ceiling", "ceil", "floor", "mod", "day", "dayofmonth", "dayofweek", "dayofyear", "hour", "minute",
        "second", "microsecond", "month", "quarter", "year", "yearweek", "weekday", "to_days", "to_seconds",
        "time_to_sec", "unix_timestamp", "from_days",
    ]

    static func preservingLiteralBytes(_ tokens: [DDLToken], charset: String) throws -> [DDLToken] {
        try require(
            charset.range(of: #"^[a-zA-Z0-9]+$"#, options: .regularExpression) != nil,
            "invalid partition literal charset")
        return try tokens.enumerated().flatMap { index, token -> [DDLToken] in
            guard let bytes = token.literalBytes else { return [token] }
            // Byte literals and explicit introducers already specify encoding.
            if index > 0
                && (["X", "B"].contains(tokens[index - 1].keyword) || tokens[index - 1].keyword.hasPrefix("_"))
            {
                return [token]
            }
            return try DDLTokens.lex(Data(("_" + charset + " " + SQLByteLiteral.sql(bytes)).utf8))
        }
    }
    static func parse(_ tokens: [DDLToken]) throws -> SQLExpression {
        do { return try SQLExpression.parse(tokens, sqlMode: 1 << 20) } catch let error as SQLSyntaxError {
            throw ApplyError(error.message)
        }
    }
    static func canonical(_ tokens: [DDLToken]) throws -> String {
        let expression = try parse(tokens)
        return try describe(expression) { expression in
            _ = try evaluationSQL(expression)
            if case .introduced = expression { return try evaluationSQL(expression) }
            if case .bytes = expression { return try evaluationSQL(expression) }
            return try DDLExpression.render(expression)
        }
    }
    static func describe(_ expression: SQLExpression, evaluate: (SQLExpression) throws -> String) throws -> String {
        if case .tuple(let values) = expression {
            return "(" + (try values.map { try describe($0, evaluate: evaluate) }).joined(separator: ",") + ")"
        }
        if let value = literal(expression) { return value }
        return try evaluate(expression)
    }
    static func literal(_ expression: SQLExpression) -> String? {
        switch expression {
        case .identifier(let token) where token.keyword == "MAXVALUE": return "MAXVALUE"
        case .literal(let token): return "'" + (token.literal ?? "").replacingOccurrences(of: "'", with: "''") + "'"
        case .number(let value) where !value.contains(".") && !value.lowercased().contains("e"):
            let trimmed = String(value.drop(while: { $0 == "0" }))
            return trimmed.isEmpty ? "0" : trimmed
        case .keyword("null"): return "NULL"
        case .keyword("true"): return "1"
        case .keyword("false"): return "0"
        case .prefix(let op, let child) where op == "+" || op == "-":
            guard let value = literal(child), value.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil else {
                return nil
            }
            if op == "+" || value == "0" { return value }
            return value.hasPrefix("-") ? String(value.dropFirst()) : "-" + value
        default: return nil
        }
    }
    static func evaluationSQL(_ expression: SQLExpression) throws -> String {
        switch expression {
        case .literal(let token): return ChoiceMetadata.literal(token.literal ?? "")
        case .number: return try DDLExpression.render(expression)
        case .bytes(let value): return SQLByteLiteral.sql(value)
        case .introduced(let name, let value):
            try require(
                name.range(of: #"^_[a-zA-Z0-9]+$"#, options: .regularExpression) != nil,
                "invalid partition charset introducer")
            switch value {
            case .bytes: return name + " " + (try evaluationSQL(value))
            case .literal(let token):
                return name + " " + SQLByteLiteral.sql(token.literalBytes ?? Data((token.literal ?? "").utf8))
            default: throw ApplyError("partition charset introducer requires a literal")
            }
        case .keyword(let value) where ["null", "true", "false"].contains(value): return value
        case .prefix(let op, let value) where ["+", "-"].contains(op):
            return "(" + op + (try evaluationSQL(value)) + ")"
        case .binary(let op, let left, let right) where ["+", "-", "*", "div", "%", "mod"].contains(op):
            return "(" + (try evaluationSQL(left)) + " " + op + " " + (try evaluationSQL(right)) + ")"
        case .call(let name, let values):
            try require(
                functions.contains(name) && !values.isEmpty,
                "nonconstant or unsupported partition bound function: " + name)
            return name + "(" + (try values.map(evaluationSQL)).joined(separator: ",") + ")"
        case .extract(let unit, let value): return "extract(" + unit + " from " + (try evaluationSQL(value)) + ")"
        case .cast(let value, let type) where ["date", "time", "datetime"].contains(type):
            return "cast(" + (try evaluationSQL(value)) + " as " + type + ")"
        default: throw ApplyError("nonconstant or unsupported partition bound")
        }
    }
    static func resolving(_ table: ApplyTable, evaluate: (String) throws -> String) throws -> ApplyTable {
        let partitions = try table.partitions.map { partition in
            let description = try partition.description.map { value in
                try splitPartitionTokens(DDLTokens.lex(Data(value.utf8), sqlMode: 1 << 20)).map {
                    try describe(parse($0)) { try evaluate(evaluationSQL($0)) }
                }.joined(separator: ",")
            }
            return ApplyPartition(
                name: partition.name, method: partition.method, expression: partition.expression,
                description: description, keyAlgorithm: partition.keyAlgorithm, subpartitions: partition.subpartitions)
        }
        return table.replacing(partitions: partitions)
    }
    static func needsEvaluation(_ table: ApplyTable) throws -> Bool {
        var needed = false
        _ = try resolving(table) { _ in
            needed = true
            return "0"
        }
        return needed
    }
    static func result(_ value: MySQLData) throws -> String {
        if value.buffer == nil { return "NULL" }
        guard let text = value.string else { throw ApplyError("unreadable native partition bound") }
        if [.tiny, .short, .long, .longlong, .int24, .year, .decimal, .newdecimal].contains(value.type) {
            try require(
                text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                "invalid numeric partition bound result")
            var result = text
            if result.contains(".") {
                while result.last == "0" { result.removeLast() }
                if result.last == "." { result.removeLast() }
            }
            return result
        }
        try require(
            [.date, .time, .datetime, .timestamp, .varString, .string].contains(value.type),
            "unsupported native partition bound result")
        return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

extension TargetSession {
    func resolvePartitionBounds(_ table: ApplyTable, context: QuerySessionContext, source: QueryControl) throws
        -> ApplyTable
    {
        guard
            try table.partitions.contains(where: { $0.method.hasSuffix("COLUMNS") })
                || PartitionBounds.needsEvaluation(table)
        else { return table }
        try setDDLSession(context, source: source)
        // These internal statements contain UTF-8 text, not the source SQL bytes.
        _ = try query("SET SESSION character_set_client=utf8mb4")
        return try withMetadataMode(String(contract.ddlSQLMode(context.sqlMode) & ~(1 << 20))) {
            try ColumnPartitionBounds.resolving(table) { expression, column in
                if !ColumnPartitionBounds.isBinary(column), let literal = PartitionBounds.literal(expression) {
                    return literal
                }
                var sql = try PartitionBounds.evaluationSQL(expression)
                if let charset = column?.characterSet {
                    let server: CharacterSetRegistry.Server = contract.versionPrefix == "5.7." ? .mysql57 : .mysql84
                    let charset = CharacterSetRegistry.charsetName(charset, on: server)
                    sql = "CONVERT(" + sql + " USING " + charset + ")"
                    if charset != "binary" { sql = "CONVERT(" + sql + " USING utf8mb4)" }
                }
                sql = ColumnPartitionBounds.resultSQL(sql, column: column)
                guard let value = try query("SELECT " + sql + " AS v", textProtocol: true).0.first?.column("v") else {
                    throw ApplyError("missing native partition bound result")
                }
                if ColumnPartitionBounds.isBinary(column), let bytes = value.buffer {
                    return SQLByteLiteral.sql(Data(bytes.readableBytesView))
                }
                return try PartitionBounds.result(value)
            }
        }
        // prepareTargetDDL restores the original source session before execution.
    }
}
