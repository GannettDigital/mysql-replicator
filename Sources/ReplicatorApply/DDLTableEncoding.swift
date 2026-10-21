import Foundation
import ReplicatorCodec

struct DDLTableEncoding: Equatable {
    var characterSet: String?
    var collation: String?
    var convert: Bool
    var usesDefault: Bool { characterSet == "default" || collation == "default" }

    func resolvingDefaults(table: DDLEncoding, session: DDLEncoding) -> Self {
        guard usesDefault else { return self }
        if convert {
            let inherited = characterSet == "default"
            return .init(
                characterSet: inherited ? session.characterSet : characterSet,
                collation: collation == nil || collation == "default"
                    ? (inherited ? session.collation : nil) : collation,
                convert: true)
        }
        // 5.7 default_collation resets default_table_charset to NULL.
        // A following explicit COLLATE replaces a DEFAULT charset without
        // constraining it to the database charset.
        if collation == "default" || (characterSet == "default" && collation == nil) {
            return .init(characterSet: table.characterSet, collation: table.collation, convert: false)
        }
        return .init(characterSet: characterSet == "default" ? nil : characterSet, collation: collation, convert: false)
    }
}

extension DDLParser {
    var isTableEncoding: Bool {
        ["DEFAULT", "CHARACTER", "CHARSET", "COLLATE"].contains { isNext($0) }
    }

    mutating func tableEncodingChange() throws -> DDLTableEncoding {
        let start = index
        let convert = take("CONVERT")
        if convert { try expect("TO") }
        var charset: String?
        var collation: String?
        var charsetEnd: Int?
        _ = take("DEFAULT")
        if take("CHARACTER") || take("CHARSET") {
            if tokens[index - 1].keyword == "CHARACTER" { try expect("SET") }
            _ = take("=")
            charset = try identifier().lowercased()
            charsetEnd = tokens[index - 1].range?.upperBound
            if !convert, isNext("DEFAULT"), index + 1 < tokens.count, tokens[index + 1].keyword == "COLLATE" {
                index += 1
            }
            if take("COLLATE") {
                _ = take("=")
                collation = try collationName()
            }
        } else if !convert, take("COLLATE") {
            _ = take("=")
            collation = try collationName()
        } else {
            throw ApplyError("expected table CHARACTER SET or COLLATE")
        }
        try require(!convert || charset != nil, "CONVERT TO requires CHARACTER SET")
        collation = charsetDefault(charset, collation: collation, at: charsetEnd)
        let change = DDLTableEncoding(characterSet: charset, collation: collation, convert: convert)
        if let first = tokens[start].range, let last = tokens[index - 1].range {
            tableEncodingRanges.append((first.lowerBound..<last.upperBound, change))
        }
        return change
    }
}

extension TargetSession {
    /// Read the native converted field before changing an application table.
    /// CTAS copies only the field definition. No application rows are read.
    /// Native ALTER supplies TEXT widening and encoded ENUM/SET/default rules.
    func convertedColumn(_ original: ApplyColumn, table: TableName, encoding: DDLEncoding, context: QuerySessionContext)
        throws -> ApplyColumn
    {
        let type = try DMLColumnType(original)
        guard type.isText && type.characterSet != "binary" else { return original }
        return try withMetadataMode(String(contract.ddlSQLMode(context.sqlMode))) {
            try withMetadataTable(database: table.database) { scratch in
                let name = try scratch.sql
                _ = try query(
                    "CREATE TEMPORARY TABLE " + name + " ENGINE=InnoDB AS SELECT CAST(0 AS UNSIGNED) AS o,"
                        + quoted(original.name) + " AS v FROM " + table.sql + " LIMIT 0", textProtocol: true)
                _ = try query(
                    "ALTER TABLE " + name + " CONVERT TO CHARACTER SET " + quoted(encoding.characterSet) + " COLLATE "
                        + quoted(encoding.collation), textProtocol: true)
                guard
                    let row = try query("SHOW FULL COLUMNS FROM " + name).0.first(where: {
                        $0.column("Field")?.string == "v"
                    }),
                    let definition = row.column("Type")?.string
                else { throw ApplyError("missing converted field metadata") }
                var result = original
                result.name = "v"
                result.characterSet = row.column("Collation")?.string == nil ? nil : encoding.characterSet
                result.collation = row.column("Collation")?.string
                result.choiceLabels = nil
                result.choiceDefaultBytes = nil
                result.choiceDefaultOrdinal = nil
                result.binaryDefaultBytes = nil
                if type.isChoice {
                    // Displayed labels can lose bytes. The old type supplies only
                    // the label count; read exact converted labels from the field.
                    result.characterSet = result.characterSet ?? "binary"
                    result.collation = result.collation ?? "binary"
                    result = try readChoiceScratch(result, name: name)
                } else {
                    result.type = definition
                    if original.hasDefaultValue {
                        if encoding.characterSet == "binary" {
                            result = try discoverBinaryDefault(result, table: scratch)
                        } else {
                            result = try discoverTextDefault(result, table: scratch)
                        }
                    }
                }
                result.name = original.name
                try result.validate()
                return result
            }
        }
    }

    func alterEncoding(_ table: ApplyTable, actions: [AlterAction], context: QuerySessionContext) throws -> (
        DDLEncoding, DDLEncoding?
    ) {
        var encoding = DDLEncoding(characterSet: table.defaultCharacterSet!, collation: table.defaultCollation!)
        var conversion: DDLEncoding?
        for action in actions {
            guard case .encoding(let change) = action else { continue }
            try require(!change.usesDefault, "unresolved table encoding DEFAULT")
            encoding = try resolveEncoding(
                charset: change.characterSet, collation: change.collation, parent: encoding, context: context)
            // Native table_charset is independent of default_table_charset.
            // A later DEFAULT COLLATE does not change the conversion collation.
            if change.convert { conversion = encoding }
        }
        return (encoding, conversion)
    }
}

extension DDLParser {
    /// Replace only parsed table encoding clauses. Keep column encodings,
    /// comments, literals and all other source bytes unchanged.
    mutating func translateTableEncodingDefaults(final: DDLEncoding, conversion: DDLEncoding?) throws {
        for (range, change) in tableEncodingRanges {
            guard let encoding = change.convert ? conversion : final else {
                throw ApplyError("missing resolved charset conversion")
            }
            edits.removeAll { range.contains($0.range.lowerBound) || $0.range.lowerBound == range.upperBound }
            let clause =
                (change.convert ? "CONVERT TO CHARACTER SET " : "DEFAULT CHARACTER SET ")
                + encoding.characterSet + " COLLATE " + encoding.collation
            edits.append(.init(range: range, replacement: clause))
        }
    }
}

extension TargetSession {
    func resolveTableEncodingDefaults(
        _ statement: DDLStatement, source: QueryControl,
        context: QuerySessionContext
    ) throws -> DDLStatement {
        guard case .alter(let name, let actions) = statement,
            actions.contains(where: {
                if case .encoding(let e) = $0 { return e.usesDefault }
                return false
            })
        else { return statement }
        let table = try databaseEncoding(name.database)
        let session: DDLEncoding
        if let id = context.databaseCollation {
            guard let c = CharacterSetRegistry.collation(id: config.compatibilityPolicy.targetID(id)) else {
                throw ApplyError("unsupported source database collation: \(id)", code: .unsupportedCollation)
            }
            session = DDLEncoding(
                characterSet: c.characterSet,
                collation: c.name(on: contract.versionPrefix == "5.7." ? .mysql57 : .mysql84) ?? c.name84)
        } else if let database = source.database, !database.isEmpty {
            session = try databaseEncoding(database)
        } else {
            // Query events omit the initial no-database default. Native 5.7
            // starts db_charset from global collation_database, not the logged
            // collation_server. Source and target baseline defaults must match.
            guard
                let row = try metadataQuery(
                    "SELECT c.CHARACTER_SET_NAME,c.COLLATION_NAME FROM information_schema.COLLATIONS c WHERE c.COLLATION_NAME=@@GLOBAL.collation_database"
                ).0.first,
                let charset = row.column("CHARACTER_SET_NAME")?.string,
                let collation = row.column("COLLATION_NAME")?.string
            else { throw ApplyError("missing target baseline database collation") }
            session = DDLEncoding(characterSet: charset, collation: collation)
        }
        return .alter(
            name,
            actions.map { action in
                guard case .encoding(let change) = action else { return action }
                return .encoding(change.resolvingDefaults(table: table, session: session))
            })
    }
}
