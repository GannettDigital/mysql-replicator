/// Standalone ALTER partition administration. An empty name list means ALL.
/// The original SQL carries the operation, options and logging modifier.
public struct SQLPartitionMaintenance: Equatable {
    public enum Operation: String {
        case rebuild = "REBUILD"
        case analyze = "ANALYZE"
        case check = "CHECK"
        case optimize = "OPTIMIZE"
        case repair = "REPAIR"
    }
    public let operation: Operation
    public let names: [String]
    public let local: Bool
    public let options: [String]

    public static func parse(_ tokens: [SQLToken]) throws -> Self {
        guard tokens.count >= 3, let operation = Operation(rawValue: tokens[0].keyword),
            tokens[1].keyword == "PARTITION"
        else { throw SQLSyntaxError("expected partition maintenance operation") }
        var i = 2
        var local = false
        func modifier() -> Bool {
            i < tokens.count && ["LOCAL", "NO_WRITE_TO_BINLOG"].contains(tokens[i].keyword)
        }
        if operation != .check && modifier() {
            local = true
            i += 1
        }
        try syntaxRequire(i < tokens.count, "missing partition selection")
        var names: [String] = []
        if tokens[i].keyword == "ALL" {
            i += 1
        } else {
            while true {
                try syntaxRequire(i < tokens.count, "missing partition name")
                let token = tokens[i]
                try syntaxRequire(
                    token.identifier
                        || (token.literal == nil && !token.text.isEmpty
                            && token.text.unicodeScalars.allSatisfy {
                                $0.value >= 128 || $0 == "_" || $0 == "$" || (65...90).contains($0.value)
                                    || (97...122).contains($0.value) || (48...57).contains($0.value)
                            }),
                    "invalid partition name")
                names.append(token.text)
                i += 1
                guard i < tokens.count && tokens[i].keyword == "," else { break }
                i += 1
            }
        }
        // Native OPTIMIZE also accepts the logging modifier after its names.
        if operation == .optimize && modifier() {
            local = true
            i += 1
        }
        var options: [String] = []
        let allowed =
            operation == .check
            ? ["QUICK", "FAST", "MEDIUM", "EXTENDED", "CHANGED"]
            : operation == .repair ? ["QUICK", "EXTENDED", "USE_FRM"] : []
        while i < tokens.count {
            if operation == .check && tokens[i].keyword == "FOR" {
                i += 1
                try syntaxRequire(
                    i < tokens.count && tokens[i].keyword == "UPGRADE", "expected FOR UPGRADE")
                options.append("FOR UPGRADE")
                i += 1
            } else {
                try syntaxRequire(
                    allowed.contains(tokens[i].keyword), "unsupported partition maintenance option")
                options.append(tokens[i].keyword)
                i += 1
            }
        }
        return .init(operation: operation, names: names, local: local, options: options)
    }
}
