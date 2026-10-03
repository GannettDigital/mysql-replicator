import Foundation
import ReplicatorCodec

/// Immutable parsed schema. Runtime-only: persisted ApplyTable stays unchanged.
struct DMLTablePlan {
    let table: ApplyTable
    let columnTypes: [DMLColumnType]

    init(_ table: ApplyTable) throws {
        self.table = table
        columnTypes = try table.columns.map { try DMLColumnType($0.type) }
    }

    func validate(_ values: [DecodedValue]) throws {
        try require(values.count == columnTypes.count,"row/manifest column count differs")
        for index in values.indices {
            if values[index] == .null {
                try require(table.columns[index].nullable,"NULL in nonnullable column")
            } else { try columnTypes[index].validate(values[index]) }
        }
    }

    func validate(wire: [WireColumn]) throws {
        try require(wire.count == columnTypes.count,"source/target column count differs")
        for index in wire.indices {
            let w = wire[index], c = table.columns[index], type = columnTypes[index]
            try require(type.matches(w) && w.nullable == c.nullable,"source/target type, signedness, encoding, precision or nullability differs")
            if type.isChoice {
                try require(w.labels != nil,"ENUM/SET requires source binlog_row_metadata=FULL to validate ordered labels")
                try require(w.labels == type.labels,"source/target ENUM/SET labels or order differ")
            }
            if type.isText {
                try require(w.collation == ["utf8mb4_general_ci":45,"utf8mb4_bin":46,"utf8mb4_unicode_ci":224][c.collation ?? ""],"source collation is unsupported by the MySQL 5.7 target or differs; no collation substitution")
            }
            if let sourceName = w.name { try require(sourceName == c.name && w.primaryKey == table.primaryKeyColumns.contains(c.name),"source/target column name or primary key differs") }
        }
    }
}

/// Owned solely by the preparation loop. The target worker has its own SQL
/// plans; ordered DDL replaces this cache after the worker has drained.
struct DMLPlanningCache {
    private(set) var tables: [String:DMLTablePlan] = [:]
    private var validatedWire: [String:[WireColumn]] = [:]

    init(_ schemas: [String:ApplyTable] = [:]) throws {
        for table in schemas.values { try insert(table) }
    }
    mutating func insert(_ table: ApplyTable) throws {
        let plan = try DMLTablePlan(table)
        tables[table.identity] = plan
        validatedWire.removeValue(forKey:table.identity)
    }
    mutating func validate(_ event: DecodedEvent) throws -> ApplyTable {
        guard let database = event.database, let name = event.table, let wire = event.wireColumns,
              let plan = tables[database + "\0" + name] else { throw ApplyError("missing table-map metadata or schema") }
        let identity = plan.table.identity
        if validatedWire[identity] != wire {
            try plan.validate(wire:wire)
            // Cache only successful validation of the complete description,
            // never numeric table IDs (which the source can reuse).
            validatedWire[identity] = wire
        }
        return plan.table
    }
}
