import Foundation

extension DDLParser {
    mutating func partitionDefinition() throws -> [ApplyPartition] {
        try expect("BY"); let linear = take("LINEAR")
        var method = try identifier().uppercased()
        try require(["RANGE","LIST","HASH","KEY"].contains(method),"unsupported partition method")
        if linear { try require(["HASH","KEY"].contains(method),"invalid LINEAR partitioning"); method = "LINEAR "+method }
        if take("COLUMNS") { try require(["RANGE","LIST"].contains(method),"invalid COLUMNS partitioning"); method += " COLUMNS" }
        // KEY's algorithm affects hashing. 5.7 and 8.4 default to algorithm 2.
        if take("ALGORITHM") { try expect("="); try require(try number() == 2,"only KEY ALGORITHM=2 is supported") }
        let expression = try partitionExpression(parenthesized())
        if method.contains("HASH") || method.contains("KEY") {
            let count = take("PARTITIONS") ? try number() : 1
            try require((1...8192).contains(count),"invalid partition count")
            return (0..<count).map { ApplyPartition(name:"p\($0)",method:method,expression:expression,description:nil) }
        }
        return try partitionItems(method:method,expression:expression)
    }
    mutating func partitionItems(method: String,expression: String) throws -> [ApplyPartition] {
        try expect("("); var partitions: [ApplyPartition] = []
        repeat {
            try expect("PARTITION"); let name = try identifier(); try expect("VALUES")
            let range = take("LESS")
            if range { try expect("THAN") } else { try expect("IN") }
            let values: String
            if take("MAXVALUE") { values = "MAXVALUE" }
            else { values = try partitionDescription(parenthesized()) }
            if take("ENGINE") {
                _ = take("="); try expect("MYISAM")
            }
            let kind = method.isEmpty ? (range ? "RANGE" : "LIST") : method
            try require(kind.hasPrefix(range ? "RANGE" : "LIST"),"partition VALUES clause differs from partition method")
            partitions.append(ApplyPartition(name:name,method:kind,expression:expression,description:values))
            try require(partitions.count <= 8192,"too many partitions")
        } while take(",")
        try expect(")"); return partitions
    }
    mutating func partitionNames() throws -> [String] {
        if take("ALL") { return [] }
        var result = [try identifier()]
        while isNext(",") && index+1 < tokens.count && !["ADD","DROP","MODIFY","CHANGE","ALTER","ALGORITHM","LOCK"].contains(tokens[index+1].keyword) {
            index += 1; result.append(try identifier())
        }
        try require(Set(result).count == result.count,"duplicate partition names"); return result
    }
}

func partitionExpression(_ tokens: [DDLToken]) throws -> String {
    try splitPartitionTokens(tokens).map { try DDLExpression.canonical($0) }.joined(separator:",")
}
func partitionDescription(_ tokens: [DDLToken]) throws -> String {
    try splitPartitionTokens(tokens).map { item in
        if item.count == 1 && item[0].keyword == "MAXVALUE" { return "MAXVALUE" }
        // Partition bounds must be constants. Do not evaluate expressions using
        // the target's current date, collation, SQL mode, or stored functions.
        try require(item.allSatisfy { $0.literal != nil || ["-","+",".","(",")",","].contains($0.keyword) || $0.text.utf8.allSatisfy({(48...57).contains($0)}) || $0.keyword == "NULL" },"unsupported partition bound")
        return item.map { $0.literal.map { "'"+$0.replacingOccurrences(of:"'",with:"''")+"'" } ?? $0.text.uppercased() }.joined()
    }.joined(separator:",")
}
private func splitPartitionTokens(_ tokens: [DDLToken]) throws -> [[DDLToken]] {
    var result: [[DDLToken]] = [[]], depth = 0
    for token in tokens {
        if token.keyword == "(" { depth += 1 }; if token.keyword == ")" { depth -= 1 }
        if token.keyword == "," && depth == 0 { result.append([]) } else { result[result.count-1].append(token) }
        try require(depth >= 0,"invalid partition expression")
    }
    try require(depth == 0 && result.allSatisfy{!$0.isEmpty},"empty partition expression")
    return result
}

extension PartitionChange {
    func applying(to table: ApplyTable) throws -> ApplyTable {
        var partitions = table.partitions
        func selected(_ names: [String],allowAll: Bool = false) throws -> [Int] {
            try require(!partitions.isEmpty,"table is not partitioned")
            if names.isEmpty { try require(allowAll,"partition list cannot be ALL"); return Array(partitions.indices) }
            return try names.map { name in
                guard let index = partitions.firstIndex(where:{$0.name == name}) else { throw ApplyError("partition is absent: "+name) }; return index
            }
        }
        func resolve(_ new: [ApplyPartition]) throws -> [ApplyPartition] {
            guard let first = partitions.first else { throw ApplyError("table is not partitioned") }
            return try new.map {
                try require(first.method.hasPrefix($0.method),"new partition method differs")
                return ApplyPartition(name:$0.name,method:first.method,expression:first.expression,description:$0.description)
            }
        }
        switch self {
        case .replace(let next): partitions = next
        case .remove: try require(!partitions.isEmpty,"table is not partitioned"); partitions = []
        case .add(let next): partitions += try resolve(next)
        case .drop(let names):
            let positions = try selected(names)
            try require(partitions[0].method.hasPrefix("RANGE") || partitions[0].method.hasPrefix("LIST"),"DROP PARTITION requires RANGE/LIST")
            partitions = partitions.enumerated().filter{!positions.contains($0.offset)}.map(\.element)
            try require(!partitions.isEmpty,"cannot drop all partitions")
        case .truncate(let names): _ = try selected(names,allowAll:true)
        case .reorganize(let names,let next):
            let positions = try selected(names).sorted(), resolved = try resolve(next)
            try require(positions == Array(positions[0]...positions.last!),"REORGANIZE requires contiguous partitions")
            partitions.replaceSubrange(positions[0]...positions.last!,with:resolved)
        case .coalesce(let count):
            try require(count > 0 && count < partitions.count && (partitions[0].method.contains("HASH") || partitions[0].method.contains("KEY")),"invalid COALESCE PARTITION")
            partitions.removeLast(count)
        case .exchange(let name,_): _ = try selected([name])
        }
        let result = table.replacing(partitions:partitions); try result.validate(); return result
    }
}

extension TargetSession {
    func readPartitions(database: String,name: String) throws -> [ApplyPartition] {
        let rows = try query("SELECT PARTITION_NAME,SUBPARTITION_NAME,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? AND PARTITION_NAME IS NOT NULL ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION",[.init(string:database),.init(string:name)]).0
        return try rows.map { row in
            try require(row.column("SUBPARTITION_NAME")?.string == nil,"subpartitioning is not supported")
            guard let name = row.column("PARTITION_NAME")?.string, let method = row.column("PARTITION_METHOD")?.string, let expression = row.column("PARTITION_EXPRESSION")?.string else { throw ApplyError("incomplete partition metadata") }
            return ApplyPartition(name:name,method:method,expression:try partitionExpression(DDLTokens.lex(Data(expression.utf8),sqlMode:1 << 20)),description:try row.column("PARTITION_DESCRIPTION")?.string.map { try partitionDescription(DDLTokens.lex(Data($0.utf8),sqlMode:1 << 20)) })
        }
    }
}
