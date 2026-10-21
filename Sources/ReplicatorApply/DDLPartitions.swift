import Foundation
import MySQLSyntax

extension DDLParser {
    mutating func partitionDefinition() throws -> [ApplyPartition] {
        do {
            let clause = try SQLPartitionClause.parsePrefix(tokens[index...])
            index += clause.consumed
            let expression = try canonicalPartitionExpression(clause.method.expression)
            let items =
                clause.items.isEmpty
                ? (0..<(clause.count ?? 1)).map {
                    SQLPartitionItem.generated(name: "p\($0)")
                } : clause.items
            let explicitCounts = items.map { $0.children.count }
            let subCount = clause.subpartition.map { _ in
                clause.subpartitionCount ?? explicitCounts.first(where: { $0 > 0 }) ?? 1
            }
            if let subCount {
                try require(items.count <= 8192 / subCount, "too many subpartitions")
                try require(
                    explicitCounts.allSatisfy { $0 == 0 } || explicitCounts.allSatisfy { $0 == subCount },
                    "inconsistent explicit subpartition counts")
            }
            return try items.map { item in
                var partition = try partitionItem(item, method: clause.method.name, expression: expression)
                partition.keyAlgorithm = clause.method.algorithm == 1 ? 1 : nil
                if let sub = clause.subpartition, let subCount {
                    let names =
                        item.children.isEmpty ? (0..<subCount).map { item.name + "sp\($0)" } : item.children.map(\.name)
                    let subExpression = try partitionExpression(sub.expression)
                    partition.subpartitions = names.map {
                        .init(
                            name: $0, method: sub.name, expression: subExpression,
                            keyAlgorithm: sub.algorithm == 1 ? 1 : nil)
                    }
                }
                return partition
            }
        } catch let error as SQLSyntaxError { throw ApplyError(error.message) }
    }
    mutating func partitionItems(method: String, expression: String) throws -> [ApplyPartition] {
        do {
            let parsed = try SQLPartitionClause.parseItemsPrefix(tokens[index...])
            index += parsed.consumed
            return try parsed.items.map { try partitionItem($0, method: method, expression: expression) }
        } catch let error as SQLSyntaxError { throw ApplyError(error.message) }
    }
    func partitionItem(_ item: SQLPartitionItem, method: String, expression: String) throws -> ApplyPartition {
        for engineName in [item.engine] + item.children.map(\.engine) {
            if let engineName {
                try require(
                    engineName.uppercased() == engine.uppercased(),
                    "explicit partition engine is outside the \(engine) DDL contract (no engine rewriting)")
            }
        }
        let kind = method.isEmpty ? item.range.map { $0 ? "RANGE" : "LIST" } ?? "" : method
        if kind.hasPrefix("RANGE") || kind.hasPrefix("LIST") {
            try require(
                item.range == kind.hasPrefix("RANGE") && item.values != nil,
                "partition VALUES clause differs from partition method")
        } else {
            try require(item.values == nil, "HASH/KEY partition cannot have VALUES")
        }
        return ApplyPartition(
            name: item.name, method: kind, expression: expression,
            description: try item.values.map { values in
                try partitionDescription(
                    PartitionBounds.preservingLiteralBytes(values, charset: partitionLiteralCharset))
            },
            subpartitions: item.children.isEmpty
                ? nil : item.children.map { .init(name: $0.name, method: "", expression: "") })
    }
    mutating func partitionNames() throws -> [String] {
        if take("ALL") { return [] }
        var result = [try identifier()]
        while isNext(",") && index + 1 < tokens.count
            && !["ADD", "DROP", "MODIFY", "CHANGE", "ALTER", "ALGORITHM", "LOCK"].contains(tokens[index + 1].keyword)
        {
            index += 1
            result.append(try identifier())
        }
        try require(Set(result.map(SQLIdentifier.key)).count == result.count, "duplicate partition names")
        return result
    }
}

private func canonicalPartitionExpression(_ tokens: [DDLToken]) throws -> String {
    tokens.isEmpty ? "" : try partitionExpression(tokens)
}

/// 5.7 exposes implicit KEY columns as an empty string; 8.4 exposes SQL NULL.
/// Both describe KEY(). Other partition methods require an expression.
func partitionMetadataExpression(_ value: String?, method: String) throws -> String {
    if value == nil || value == "" {
        try require(["KEY", "LINEAR KEY"].contains(method), "missing partition expression for " + method)
        return ""
    }
    return try partitionExpression(DDLTokens.lex(Data(value!.utf8), sqlMode: 1 << 20))
}

func partitionExpression(_ tokens: [DDLToken]) throws -> String {
    try splitPartitionTokens(tokens).map { try DDLExpression.canonical($0) }.joined(separator: ",")
}
func partitionDescription(_ tokens: [DDLToken]) throws -> String {
    try splitPartitionTokens(tokens).map { try PartitionBounds.canonical($0) }.joined(separator: ",")
}
func splitPartitionTokens(_ tokens: [DDLToken]) throws -> [[DDLToken]] {
    var result: [[DDLToken]] = [[]]
    var depth = 0
    for token in tokens {
        if token.keyword == "(" { depth += 1 }
        if token.keyword == ")" { depth -= 1 }
        if token.keyword == "," && depth == 0 { result.append([]) } else { result[result.count - 1].append(token) }
        try require(depth >= 0, "invalid partition expression")
    }
    try require(depth == 0 && result.allSatisfy { !$0.isEmpty }, "empty partition expression")
    return result
}

extension PartitionChange {
    func applying(to table: ApplyTable) throws -> ApplyTable {
        var partitions = table.partitions
        func selected(_ names: [String], allowAll: Bool = false) throws -> [Int] {
            try require(!partitions.isEmpty, "table is not partitioned")
            if names.isEmpty {
                try require(allowAll, "partition list cannot be ALL")
                return Array(partitions.indices)
            }
            return try names.map { name in
                guard let index = partitions.firstIndex(where: { SQLIdentifier.equal($0.name, name) }) else {
                    throw ApplyError("partition is absent: " + name)
                }
                return index
            }
        }
        func resolve(_ new: [ApplyPartition]) throws -> [ApplyPartition] {
            guard let first = partitions.first else { throw ApplyError("table is not partitioned") }
            return try new.map {
                try require(first.method.hasPrefix($0.method), "new partition method differs")
                var result = ApplyPartition(
                    name: $0.name, method: first.method, expression: first.expression, description: $0.description,
                    keyAlgorithm: first.keyAlgorithm)
                if let children = first.subpartitions, let child = children.first {
                    let names = $0.subpartitions?.map(\.name) ?? (0..<children.count).map { result.name + "sp\($0)" }
                    try require(names.count == children.count, "subpartition count differs from the table")
                    result.subpartitions = names.map {
                        .init(
                            name: $0, method: child.method, expression: child.expression,
                            keyAlgorithm: child.keyAlgorithm)
                    }
                } else {
                    try require($0.subpartitions == nil, "table is not subpartitioned")
                }
                return result
            }
        }
        switch self {
        case .replace(let next): partitions = next
        case .remove:
            try require(!partitions.isEmpty, "table is not partitioned")
            partitions = []
        case .add(let next): partitions += try resolve(next)
        case .addHash(let count):
            guard let first = partitions.first else { throw ApplyError("table is not partitioned") }
            try require(
                (first.method.contains("HASH") || first.method.contains("KEY")) && count > 0
                    && count <= 8192 - partitions.count, "invalid ADD PARTITION count")
            partitions += (partitions.count..<(partitions.count + count)).map {
                ApplyPartition(
                    name: "p\($0)", method: first.method, expression: first.expression, description: nil,
                    keyAlgorithm: first.keyAlgorithm)
            }
        case .drop(let names):
            let positions = try selected(names)
            try require(
                partitions[0].method.hasPrefix("RANGE") || partitions[0].method.hasPrefix("LIST"),
                "DROP PARTITION requires RANGE/LIST")
            partitions = partitions.enumerated().filter { !positions.contains($0.offset) }.map(\.element)
            try require(!partitions.isEmpty, "cannot drop all partitions")
        case .truncate(let names):
            let allowed = Set(
                partitions.flatMap { [$0.name] + ($0.subpartitions ?? []).map(\.name) }.map(SQLIdentifier.key))
            try require(
                !partitions.isEmpty && names.allSatisfy { allowed.contains(SQLIdentifier.key($0)) },
                "partition or subpartition is absent")
        case .reorganize(let names, let next):
            let positions = try selected(names).sorted()
            let resolved = try resolve(next)
            try require(positions == Array(positions[0]...positions.last!), "REORGANIZE requires contiguous partitions")
            partitions.replaceSubrange(positions[0]...positions.last!, with: resolved)
        case .coalesce(let count):
            try require(
                count > 0 && count < partitions.count
                    && (partitions[0].method.contains("HASH") || partitions[0].method.contains("KEY")),
                "invalid COALESCE PARTITION")
            partitions.removeLast(count)
        case .maintenance(let operation):
            let allowed = Set(
                partitions.flatMap { [$0.name] + ($0.subpartitions ?? []).map(\.name) }.map(SQLIdentifier.key))
            try require(
                !partitions.isEmpty && operation.names.allSatisfy { allowed.contains(SQLIdentifier.key($0)) },
                "partition or subpartition is absent")
        case .exchange(let name, _):
            let leaves = partitions.flatMap { $0.subpartitions?.map(\.name) ?? [$0.name] }
            try require(
                leaves.contains { SQLIdentifier.equal($0, name) },
                "EXCHANGE requires a partition without subpartitions, or one subpartition")
        }
        let result = table.replacing(partitions: partitions)
        try result.validate()
        return result
    }
}

extension TargetSession {
    func readPartitions(database: String, name: String, columns: [ApplyColumn]) throws -> [ApplyPartition] {
        let rows = try metadataQuery(
            "SELECT PARTITION_NAME,SUBPARTITION_NAME,PARTITION_METHOD,SUBPARTITION_METHOD,PARTITION_EXPRESSION,SUBPARTITION_EXPRESSION,PARTITION_DESCRIPTION FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? AND PARTITION_NAME IS NOT NULL ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION",
            [.init(string: database), .init(string: name)]
        ).0
        var result: [ApplyPartition] = []
        for row in rows {
            guard let name = row.column("PARTITION_NAME")?.string, let method = row.column("PARTITION_METHOD")?.string
            else { throw ApplyError("incomplete partition metadata") }
            var partition = ApplyPartition(
                name: name, method: method,
                expression: try partitionMetadataExpression(row.column("PARTITION_EXPRESSION")?.string, method: method),
                description: try (method.hasSuffix("COLUMNS") ? nil : row.column("PARTITION_DESCRIPTION")?.string).map {
                    try partitionDescription(DDLTokens.lex(Data($0.utf8), sqlMode: 1 << 20))
                })
            if let subName = row.column("SUBPARTITION_NAME")?.string {
                guard let subMethod = row.column("SUBPARTITION_METHOD")?.string,
                    let subExpression = row.column("SUBPARTITION_EXPRESSION")?.string
                else { throw ApplyError("incomplete subpartition metadata") }
                let child = ApplySubpartition(
                    name: subName, method: subMethod,
                    expression: try partitionExpression(DDLTokens.lex(Data(subExpression.utf8), sqlMode: 1 << 20)))
                if result.last?.name == name {
                    result[result.count - 1].subpartitions!.append(child)
                    continue
                }
                partition.subpartitions = [child]
            }
            result.append(partition)
        }
        if result.contains(where: { $0.method.hasSuffix("COLUMNS") }) {
            _ = try query("SET SESSION sql_quote_show_create=1")
            guard let previous = try scalar("SELECT @@SESSION.character_set_results AS v") else {
                throw ApplyError("missing result charset")
            }
            _ = try query("SET SESSION character_set_results=binary")
            let outcome: Result<Data, Error>
            do {
                guard
                    let buffer = try query(
                        "SHOW CREATE TABLE " + quoted(database) + "." + quoted(name), textProtocol: true
                    ).0.first?.column("Create Table")?.buffer
                else { throw ApplyError("missing native partition bounds") }
                outcome = .success(Data(buffer.readableBytesView))
            } catch { outcome = .failure(error) }
            do { _ = try query("SET SESSION character_set_results=?", [.init(string: previous)]) } catch {
                try? connection.close().wait()
                throw error
            }
            var table = ApplyTable(database: database, table: name, columns: columns, primaryKeyColumns: [])
            table.partitions = result
            result = try ColumnPartitionBounds.metadata(outcome.get(), table: table)
            table.partitions = result
            result = try ColumnPartitionBounds.resolving(table) { expression, column in
                if let literal = PartitionBounds.literal(expression) { return literal }
                if case .bytes(let bytes) = expression { return SQLByteLiteral.sql(bytes) }
                let sql = try PartitionBounds.evaluationSQL(expression)
                guard
                    let value = try query("SELECT CONVERT(" + sql + " USING utf8mb4) AS v", textProtocol: true).0.first?
                        .column("v")
                else { throw ApplyError("missing native bound conversion") }
                return try PartitionBounds.result(value)
            }.partitions
        }
        if result.contains(where: {
            $0.method.contains("KEY") || ($0.subpartitions ?? []).contains(where: { $0.method.contains("KEY") })
        }) {
            _ = try query("SET SESSION sql_quote_show_create=1")
            let rows = try query("SHOW CREATE TABLE " + quoted(database) + "." + quoted(name)).0
            guard let sql = rows.first?.column("Create Table")?.string else {
                throw ApplyError("missing native partition KEY metadata")
            }
            result = try PartitionKeyMetadata.applying(Data(sql.utf8), to: result)
        }
        return result
    }
}
