import Foundation
import MySQLSyntax

/// COLUMNS metadata retains the Item value, not the field's padded or parsed
/// representation. Native DDL validates the field conversion when it executes.
enum ColumnPartitionBounds {
    static func isBinary(_ column: ApplyColumn?) -> Bool {
        guard let column else { return false }
        return column.characterSet == "binary" || column.type.hasPrefix("binary(")
            || column.type.hasPrefix("varbinary(")
    }
    static func resultSQL(_ expression: String, column: ApplyColumn?) -> String {
        isBinary(column) ? "CAST(" + expression + " AS BINARY)" : expression
    }
    static func columns(_ partition: ApplyPartition, table: ApplyTable) throws -> [ApplyColumn] {
        guard partition.method.hasSuffix("COLUMNS") else { return [] }
        return try splitPartitionTokens(DDLTokens.lex(Data(partition.expression.utf8))).map { tokens in
            guard tokens.count == 1,
                let column = table.columns.first(where: { SQLIdentifier.equal($0.name, tokens[0].text) })
            else {
                throw ApplyError("partition column is absent from schema")
            }
            return column
        }
    }
    static func resolving(_ table: ApplyTable, evaluate: (SQLExpression, ApplyColumn?) throws -> String) throws
        -> ApplyTable
    {
        var result = table
        result.partitions = try table.partitions.map { partition in
            var result = partition
            let columns = try columns(partition, table: table)
            if let text = partition.description {
                let values = try splitPartitionTokens(DDLTokens.lex(Data(text.utf8), sqlMode: 1 << 20)).map(
                    PartitionBounds.parse)
                func leaf(_ value: SQLExpression, _ index: Int) throws -> String {
                    if case .identifier(let token) = value, token.keyword == "MAXVALUE" { return "MAXVALUE" }
                    if case .keyword("null") = value { return "NULL" }
                    let column = columns.isEmpty ? nil : columns[index]
                    return try evaluate(value, column)
                }
                if partition.method == "RANGE COLUMNS" {
                    try require(values.count == columns.count, "partition bound column count differs")
                    result.description = try values.enumerated().map { try leaf($0.element, $0.offset) }.joined(
                        separator: ",")
                } else {
                    result.description = try values.map { value in
                        if case .tuple(let tuple) = value {
                            try require(tuple.count == columns.count, "partition bound tuple count differs")
                            return "("
                                + (try tuple.enumerated().map { try leaf($0.element, $0.offset) }).joined(
                                    separator: ",") + ")"
                        }
                        try require(columns.count <= 1, "partition bound requires a tuple")
                        return try leaf(value, 0)
                    }.joined(separator: ",")
                }
            }
            return result
        }
        return result
    }

    /// SHOW CREATE with binary results preserves bytes which I_S can truncate.
    /// MySQL emits backslash escapes here, regardless of the DDL session mode.
    static func metadata(_ data: Data, table: ApplyTable) throws -> [ApplyPartition] {
        let tokens = try DDLTokens.lex(data, nativeMetadata: true) { bytes, identifier in
            if identifier {
                guard let value = String(data: bytes, encoding: .utf8) else {
                    throw ApplyError("invalid native partition identifier")
                }
                return .init(text: value, bytes: nil)
            }
            return .init(text: String(decoding: bytes, as: UTF8.self), bytes: bytes)
        }
        guard let clause = try SQLPartitionClause.fromCreateTable(tokens) else {
            throw ApplyError("missing native COLUMNS partition definition")
        }
        var scratch = table
        scratch.partitions = try table.partitions.map { partition in
            guard let item = clause.items.first(where: { SQLIdentifier.equal($0.name, partition.name) }),
                let tokens = item.values
            else { throw ApplyError("missing native partition bounds") }
            var result = partition
            let columns = try columns(partition, table: table)
            // Convert literal bytes before the general canonical text path.
            func bound(_ tokens: [DDLToken], column: ApplyColumn) throws -> String {
                if tokens.count == 1, let literal = tokens[0].literal {
                    if isBinary(column) {
                        return SQLByteLiteral.sql(tokens[0].literalBytes ?? Data(literal.utf8))
                    }
                    guard let text = String(data: tokens[0].literalBytes ?? Data(literal.utf8), encoding: .utf8) else {
                        throw ApplyError("invalid native text partition bound")
                    }
                    return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
                }
                let expression = try PartitionBounds.parse(tokens)
                if isBinary(column), case .introduced("_binary", .bytes(let bytes)) = expression {
                    return SQLByteLiteral.sql(bytes)
                }
                return try PartitionBounds.canonical(tokens)
            }
            let values = try splitPartitionTokens(tokens)
            if partition.method == "RANGE COLUMNS" {
                try require(values.count == columns.count, "native partition column count differs")
                result.description = try zip(values, columns).map { try bound($0.0, column: $0.1) }.joined(
                    separator: ",")
            } else {
                result.description = try values.map { value in
                    if columns.count == 1 { return try bound(value, column: columns[0]) }
                    try require(
                        value.first?.keyword == "(" && value.last?.keyword == ")", "native partition tuple is missing")
                    let tuple = try splitPartitionTokens(Array(value.dropFirst().dropLast()))
                    try require(tuple.count == columns.count, "native partition tuple count differs")
                    return "(" + (try zip(tuple, columns).map { try bound($0.0, column: $0.1) }).joined(separator: ",")
                        + ")"
                }.joined(separator: ",")
            }
            return result
        }
        return scratch.partitions
    }
}
