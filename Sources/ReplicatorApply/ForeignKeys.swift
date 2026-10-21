import Foundation
import MySQLNIO

/// Relationship evidence is saved with each table in the connected component.
/// Binlog row events do not contain InnoDB's implicit cascade row images.
public struct ApplyForeignKey: Codable, Equatable {
    public var name: String
    public var database: String
    public var table: String
    public var columns: [String]
    public var referencedDatabase: String
    public var referencedTable: String
    public var referencedColumns: [String]
    public var onUpdate: String = "RESTRICT"
    public var onDelete: String = "RESTRICT"
    var child: SQLNameKey { .table(database, table) }
    var parent: SQLNameKey { .table(referencedDatabase, referencedTable) }
    var identity: SQLNameKey { SQLNameKey(database + "\0" + table + "\0" + SQLIdentifier.lowercase(name)) }
    func validate() throws {
        for identifier in [name, database, table, referencedDatabase, referencedTable] + columns + referencedColumns {
            _ = try quoted(identifier)
        }
        try require(
            (1...16).contains(columns.count) && columns.count == referencedColumns.count
                && Set(columns.map(SQLIdentifier.key)).count == columns.count
                && Set(referencedColumns.map(SQLIdentifier.key)).count == columns.count, "invalid foreign-key columns")
        try require(
            ["RESTRICT", "NO ACTION", "CASCADE", "SET NULL"].contains(onUpdate)
                && ["RESTRICT", "NO ACTION", "CASCADE", "SET NULL"].contains(onDelete), "unsupported foreign-key action"
        )
    }
}

enum ForeignKeyGraph {
    static func sorted(_ keys: [ApplyForeignKey]) -> [ApplyForeignKey] { keys.sorted { $0.identity < $1.identity } }
    static func component(_ identity: SQLNameKey, in keys: [ApplyForeignKey]) -> [ApplyForeignKey] {
        var members: Set<SQLNameKey> = [identity]
        var changed = true
        while changed {
            changed = false
            for key in keys where members.contains(key.child) || members.contains(key.parent) {
                if members.insert(key.child).inserted { changed = true }
                if members.insert(key.parent).inserted { changed = true }
            }
        }
        return sorted(keys.filter { members.contains($0.child) })
    }
    static func validate(
        _ keys: [ApplyForeignKey], tables: [SQLNameKey: ApplyTable], filter: TableFilter,
        missingParents: Set<SQLNameKey> = [], parentKeys: NativeReplicationRules.ForeignKeyParentKeys = .completeUnique
    ) throws {
        try require(
            keys.count <= 256 && Set(keys.map(\.identity)).count == keys.count,
            "duplicate or excessive foreign-key relationships")
        try require(Set(keys.flatMap { [$0.child, $0.parent] }).count <= 64, "foreign-key component exceeds 64 tables")
        for key in keys {
            try key.validate()
            try require(
                !filter.ignores(database: key.database, table: key.table)
                    && !filter.ignores(database: key.referencedDatabase, table: key.referencedTable),
                "foreign key \(key.name) crosses an excluded table")
            guard let child = tables[key.child] else {
                throw ApplyError("foreign key \(key.name) has an absent child table")
            }
            try require(child.partitions.isEmpty, "partitioned foreign-key tables are unsupported")
            try require(child.hasForeignKeyIndex(key.columns), "foreign key \(key.name) lacks a supporting child index")
            for childName in key.columns {
                guard let c = child.columns.first(where: { SQLIdentifier.equal($0.name, childName) }) else {
                    throw ApplyError("foreign-key child column is absent")
                }
                try ForeignKeyGeneratedColumns.validateChild(c, key: key)
                if key.onDelete == "SET NULL" || key.onUpdate == "SET NULL" {
                    try require(c.nullable, "SET NULL requires nullable child columns")
                }
            }
            guard let parent = tables[key.parent] else {
                try require(
                    missingParents.contains(key.parent),
                    "foreign key \(key.name) references an absent parent table; foreign_key_checks must be disabled for this DDL"
                )
                continue
            }
            try require(parent.partitions.isEmpty, "partitioned foreign-key tables are unsupported")
            let reason =
                parentKeys == .completeUnique
                ? "requires a complete unique parent key"
                : "requires a supporting parent index with full leading columns"
            try require(
                parent.hasForeignKeyParentIndex(key.referencedColumns, rule: parentKeys),
                "foreign key \(key.name) \(reason)")
            for (childName, parentName) in zip(key.columns, key.referencedColumns) {
                guard let c = child.columns.first(where: { SQLIdentifier.equal($0.name, childName) }),
                    let p = parent.columns.first(where: { SQLIdentifier.equal($0.name, parentName) })
                else { throw ApplyError("foreign-key column is absent") }
                try ForeignKeyGeneratedColumns.validateParent(p)
                try require(
                    try ForeignKeyColumnCompatibility.matches(c, p), "foreign-key column types/encodings differ")
            }
        }
    }
}

extension ApplyTable {
    func hasForeignKeyIndex(_ names: [String]) -> Bool {
        primaryKeyCovers(names)
            || secondaryIndexes.contains {
                $0.type == "BTREE"
                    && SQLIdentifier.equal(Array($0.parts.prefix(names.count)).map { $0.column ?? "" }, names)
                    && $0.parts.prefix(names.count).allSatisfy { $0.prefix == nil }
            }
    }
    func addingForeignKey(_ definition: ApplyForeignKey, indexName: String?) throws -> ApplyTable {
        var key = definition
        var result = self
        if key.name.isEmpty {
            let prefix = table + "_ibfk_"
            let highest =
                foreignKeys.filter { $0.child == identity && $0.name.hasPrefix(prefix) }.compactMap {
                    Int($0.name.dropFirst(prefix.count))
                }.max() ?? 0
            try require(highest < Int.max, "generated foreign-key name limit exceeded")
            key.name = prefix + String(highest + 1)
        }
        try key.validate()
        try require(!foreignKeys.contains { $0.identity == key.identity }, "duplicate foreign-key name")
        if !hasForeignKeyIndex(key.columns) {
            var name = indexName ?? (definition.name.isEmpty ? key.columns[0] : key.name)
            if indexName == nil && definition.name.isEmpty {
                var suffix = 2
                while secondaryIndexes.contains(where: { SQLIdentifier.equal($0.name, name) }) {
                    name = key.columns[0] + "_" + String(suffix)
                    suffix += 1
                }
            }
            result.secondaryIndexes.append(
                ApplyIndex(
                    name: name, unique: false, parts: key.columns.map { ApplyIndexPart(column: $0, prefix: nil) }))
            result.secondaryIndexes.sort { SQLIdentifier.key($0.name) < SQLIdentifier.key($1.name) }
        }
        result.foreignKeys = ForeignKeyGraph.sorted(foreignKeys + [key])
        return result
    }
}

extension TargetSession {
    func requireForeignKeyVisibility() throws {
        // Metadata visibility must include unknown incoming relationships, not
        // only tables already encountered in the binlog.
        let grantee = "CONCAT(CHAR(39),REPLACE(CURRENT_USER(),'@',CONCAT(CHAR(39),'@',CHAR(39))),CHAR(39))"
        try require(
            try metadataScalar(
                "SELECT EXISTS(SELECT 1 FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=\(grantee) AND PRIVILEGE_TYPE='REFERENCES') AS v"
            ) == "1", "global REFERENCES privilege required for complete foreign-key discovery")
    }
    /// Read a bounded connected component in either direction. No row-path query.
    func readForeignKeys(_ name: TableName) throws -> [ApplyForeignKey] {
        try requireForeignKeyVisibility()
        var pending = [name]
        var seen = Set<SQLNameKey>()
        var keys: [SQLNameKey: ApplyForeignKey] = [:]
        while let next = pending.popLast() {
            if !seen.insert(next.identity).inserted { continue }
            try require(seen.count <= 64, "foreign-key component exceeds 64 tables")
            let binds: [MySQLData] = [.init(string: next.database), .init(string: next.table)]
            let rows = try metadataQuery(
                "SELECT k.CONSTRAINT_NAME,k.TABLE_SCHEMA,k.TABLE_NAME,k.COLUMN_NAME,k.REFERENCED_TABLE_SCHEMA,k.REFERENCED_TABLE_NAME,k.REFERENCED_COLUMN_NAME,k.ORDINAL_POSITION,r.UPDATE_RULE,r.DELETE_RULE FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON BINARY r.CONSTRAINT_SCHEMA=BINARY k.CONSTRAINT_SCHEMA AND BINARY r.CONSTRAINT_NAME=BINARY k.CONSTRAINT_NAME AND BINARY r.TABLE_NAME=BINARY k.TABLE_NAME WHERE k.REFERENCED_TABLE_NAME IS NOT NULL AND ((BINARY k.TABLE_SCHEMA=? AND BINARY k.TABLE_NAME=?) OR (BINARY k.REFERENCED_TABLE_SCHEMA=? AND BINARY k.REFERENCED_TABLE_NAME=?)) ORDER BY BINARY k.TABLE_SCHEMA,BINARY k.TABLE_NAME,BINARY k.CONSTRAINT_NAME,k.ORDINAL_POSITION",
                binds + binds, table: next
            ).0
            var local: [ApplyForeignKey] = []
            for row in rows {
                func value(_ field: String) throws -> String {
                    guard let value = row.column(field)?.string else {
                        throw ApplyError("incomplete foreign-key metadata: \(field)")
                    }
                    return value
                }
                let key = try ApplyForeignKey(
                    name: value("CONSTRAINT_NAME"), database: value("TABLE_SCHEMA"), table: value("TABLE_NAME"),
                    columns: [value("COLUMN_NAME")], referencedDatabase: value("REFERENCED_TABLE_SCHEMA"),
                    referencedTable: value("REFERENCED_TABLE_NAME"),
                    referencedColumns: [value("REFERENCED_COLUMN_NAME")], onUpdate: value("UPDATE_RULE"),
                    onDelete: value("DELETE_RULE"))
                if let previous = local.last, previous.identity == key.identity {
                    try require(
                        row.column("ORDINAL_POSITION")?.int == previous.columns.count + 1, "invalid foreign-key ordinal"
                    )
                    local[local.count - 1].columns += key.columns
                    local[local.count - 1].referencedColumns += key.referencedColumns
                } else {
                    try require(row.column("ORDINAL_POSITION")?.int == 1, "invalid foreign-key ordinal")
                    local.append(key)
                }
            }
            for key in local {
                keys[key.identity] = key
                pending += [
                    TableName(database: key.database, table: key.table),
                    TableName(database: key.referencedDatabase, table: key.referencedTable),
                ]
            }
            try require(keys.count <= 256, "foreign-key relationship limit exceeded")
        }
        return ForeignKeyGraph.sorted(Array(keys.values))
    }
    func validateForeignKeys(_ table: ApplyTable) throws {
        let actual = try readForeignKeys(TableName(database: table.database, table: table.table))
        try require(actual == table.foreignKeys, "target foreign keys differ from historical schema")
        guard !actual.isEmpty else { return }
        var tables = [table.identity: table]
        var missing = Set<SQLNameKey>()
        for key in actual {
            for name in [
                TableName(database: key.database, table: key.table),
                TableName(database: key.referencedDatabase, table: key.referencedTable),
            ] where tables[name.identity] == nil && !missing.contains(name.identity) {
                guard try tableExists(name) else {
                    missing.insert(name.identity)
                    continue
                }
                tables[name.identity] = try readSchema(
                    database: name.database, name: name.table, validateRelationships: false)
            }
        }
        try ForeignKeyGraph.validate(
            actual, tables: tables,
            filter: TableFilter(
                config.replicateWildIgnoreTable ?? [], including: config.replicateWildDoTable ?? [],
                lowerCaseTableNames: config.source.tableNameCaseSetting), missingParents: missing,
            parentKeys: NativeReplicationRules(profile: config.replicationProfile).foreignKeyParentKeys)
    }
}
