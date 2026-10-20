import Foundation

/// These options do not change row-event decoding or row identity. The original
/// SQL stays in the DDL intent. The target applies its engine's physical options;
/// a physical format or comment is not part of the saved row schema.
struct DDLTableOption: Equatable {
    let name: String
}

extension DDLParser {
    var isTableOption: Bool {
        [
            "COMMENT", "ROW_FORMAT", "AUTO_INCREMENT", "AVG_ROW_LENGTH", "MAX_ROWS", "MIN_ROWS",
            "KEY_BLOCK_SIZE", "STATS_SAMPLE_PAGES", "STATS_AUTO_RECALC", "STATS_PERSISTENT",
            "CHECKSUM", "DELAY_KEY_WRITE", "PACK_KEYS", "ENGINE", "TABLESPACE", "STORAGE",
            "COMPRESSION", "ENCRYPTION", "CONNECTION", "PASSWORD", "DATA", "INDEX", "INSERT_METHOD", "UNION",
            "AUTOEXTEND_SIZE", "ENGINE_ATTRIBUTE", "SECONDARY_ENGINE_ATTRIBUTE", "SECONDARY_ENGINE",
        ].contains { isNext($0) }
    }
    mutating func consumeCommentLiteral() throws {
        guard index < tokens.count, tokens[index].literal != nil else {
            throw ApplyError("COMMENT requires a string literal")
        }
        index += 1
    }
    mutating func tableOption() throws -> DDLTableOption {
        let name = try identifier().uppercased()
        _ = take("=")
        if ["DATA", "INDEX"].contains(name) {
            try expect("DIRECTORY")
            _ = take("=")
            try consumeCommentLiteral()
            return .init(name: name + " DIRECTORY")
        }
        if name == "UNION" {
            try expect("(")
            if !take(")") {
                _ = try self.name()
                while take(",") { _ = try self.name() }
                try expect(")")
            }
            return .init(name: name)
        }
        if name == "TABLESPACE" {
            _ = try identifier()
            if take("STORAGE") { try require(take("DISK") || take("MEMORY"), "invalid TABLESPACE STORAGE") }
            return .init(name: name)
        }
        if ["AUTOEXTEND_SIZE", "ENGINE_ATTRIBUTE", "SECONDARY_ENGINE_ATTRIBUTE", "SECONDARY_ENGINE"].contains(name) {
            try require(targetVersion != "5.7.", "target MySQL 5.7 does not support table option " + name)
        }
        if [
            "COMMENT", "COMPRESSION", "ENCRYPTION", "CONNECTION", "PASSWORD", "ENGINE_ATTRIBUTE",
            "SECONDARY_ENGINE_ATTRIBUTE",
        ].contains(name) {
            try consumeCommentLiteral()
            return DDLTableOption(name: name)
        }
        let value: String
        if index < tokens.count, let literal = tokens[index].literal, name == "ENGINE" {
            value = literal
            index += 1
        } else {
            value = try identifier()
        }
        switch name {
        case "ENGINE":
            try require(
                value.uppercased() == engine.uppercased(),
                "explicit engine is outside the \(engine) DDL contract (no engine rewriting)")
        case "SECONDARY_ENGINE": break  // Native target checks the engine plugin.
        case "STORAGE":
            try require(["DISK", "MEMORY", "DEFAULT"].contains(value.uppercased()), "invalid STORAGE value")
        case "INSERT_METHOD":
            try require(["NO", "FIRST", "LAST"].contains(value.uppercased()), "invalid INSERT_METHOD")
        case "ROW_FORMAT":
            try require(
                ["DEFAULT", "DYNAMIC", "FIXED", "COMPRESSED", "REDUNDANT", "COMPACT"].contains(value.uppercased()),
                "unsupported ROW_FORMAT value")
        case "STATS_AUTO_RECALC", "STATS_PERSISTENT", "PACK_KEYS":
            try require(["DEFAULT", "0", "1"].contains(value.uppercased()), "invalid \(name) value")
        case "STATS_SAMPLE_PAGES" where value.uppercased() == "DEFAULT": break
        case "CHECKSUM", "DELAY_KEY_WRITE": try require(["0", "1"].contains(value), "invalid \(name) value")
        case "AUTO_INCREMENT", "AVG_ROW_LENGTH", "MAX_ROWS", "MIN_ROWS", "KEY_BLOCK_SIZE", "STATS_SAMPLE_PAGES",
            "AUTOEXTEND_SIZE":
            try require(
                !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && UInt64(value) != nil,
                "invalid \(name) integer")
        default: throw ApplyError("unsupported table option: \(name)")
        }
        return DDLTableOption(name: name)
    }
}
