import Foundation
import ReplicatorCodec

/// Immutable parsed schema. Runtime-only: persisted ApplyTable stays unchanged.
struct DMLTablePlan {
    let table: ApplyTable
    let columnTypes: [DMLColumnType]
    let compatibility: CompatibilityPolicy

    init(_ table: ApplyTable,compatibility: CompatibilityPolicy = .init()) throws {
        self.compatibility = compatibility
        self.table = table
        columnTypes = try table.columns.map { try DMLColumnType($0) }
    }

    func validate(_ values: [DecodedValue]) throws {
        try require(values.count == columnTypes.count,"row/manifest column count differs")
        for index in values.indices {
            if values[index] == .null {
                try require(table.columns[index].nullable,"NULL in nonnullable column")
            } else { try columnTypes[index].validate(values[index]) }
        }
    }

    /// Legacy mode fills only absent optional 5.7 metadata from a matching seed
    /// schema. Present wire facts must still agree; never override a conflict.
    func validate(wire: [WireColumn], legacyMetadata: Bool = false) throws {
        try require(wire.count == columnTypes.count,"source/target column count differs")
        for index in wire.indices {
            let w = wire[index], c = table.columns[index], type = columnTypes[index]
            try require(type.matches(w,legacyMetadata:legacyMetadata) && w.nullable == c.nullable,"source/target type, signedness, encoding, precision or nullability differs")
            if type.isChoice {
                try require(legacyMetadata || w.labels != nil,"ENUM/SET requires source binlog_row_metadata=FULL to validate ordered labels")
                if let labels = w.labels { try require(labels == type.labels,"source/target ENUM/SET labels or order differ") }
            }
            if type.isText && !(legacyMetadata && w.collation == 0) {
                try require(compatibility.targetID(w.collation) == (type.isChoice && c.collation == "binary" ? 63 : CharacterSetRegistry.columnCollation(named:c.collation ?? "")?.id),"source collation ID \(w.collation) does not match target \(c.collation ?? "missing") under configured compatibility.collations")
            }
            if let sourceName = w.name { try require(SQLTextBytes.equal(sourceName,c.name) && w.primaryKey == SQLIdentifier.contains(table.primaryKeyColumns,c.name),"source/target column name or primary key differs") }
        }
    }
}

/// Owned solely by the preparation loop. The target worker has its own SQL
/// plans; ordered DDL replaces this cache after the worker has drained.
struct DMLPlanningCache {
    private(set) var tables: [SQLNameKey:DMLTablePlan] = [:]
    private var validatedWire: [SQLNameKey:[WireColumn]] = [:]

    let compatibility: CompatibilityPolicy
    let legacyMetadata: Bool
    init(_ schemas: [SQLNameKey:ApplyTable] = [:],compatibility: CompatibilityPolicy = .init(), legacyMetadata: Bool = false) throws {
        self.compatibility = compatibility
        self.legacyMetadata = legacyMetadata
        for table in schemas.values { try insert(table) }
    }
    mutating func insert(_ table: ApplyTable) throws {
        let plan = try DMLTablePlan(table,compatibility:compatibility)
        tables[table.identity] = plan
        validatedWire.removeValue(forKey:table.identity)
    }
    mutating func validate(_ event: DecodedEvent) throws -> ApplyTable {
        guard let database = event.database, let name = event.table, let wire = event.wireColumns,
              let plan = tables[.table(database,name)] else { throw ApplyError("missing table-map metadata or schema") }
        let identity = plan.table.identity
        if validatedWire[identity] != wire {
            try plan.validate(wire:wire,legacyMetadata:legacyMetadata)
            // Cache only successful validation of the complete description,
            // never numeric table IDs (which the source can reuse).
            validatedWire[identity] = wire
        }
        return plan.table
    }
}
