import ReplicatorCodec

/// Select before journaling or target writes. One source GTID uses one executor.
/// Unknown events and malformed bytes are not reasons to retry through SQL.
enum DMLSQLReason: String {
    case generatedColumns = "generated-columns"
    case filteredGroup = "filtered-group"
    case partialJSON = "partial-json"
    case jsonYear = "json-year"
    case collationMapping = "collation-mapping"

    static func select(
        _ group: CompleteTransaction, mutations: [Mutation], compatibility: CompatibilityPolicy
    ) -> Self? {
        if group.events.contains(where: { $0.replicationFiltered }) { return .filteredGroup }
        if mutations.contains(where: { $0.table.columns.contains(where: \.isGenerated) }) {
            return .generatedColumns
        }
        if group.events.contains(where: { $0.eventType == 39 }) { return .partialJSON }
        if compatibility.jsonYearToInteger,
            mutations.contains(where: { mutation in
                ((mutation.row.before ?? []) + (mutation.row.after ?? [])).contains { value in
                    if case .json(let document) = value {
                        return document.typedValues.contains { $0.scalar.type == 13 }
                    }
                    return false
                }
            })
        {
            return .jsonYear
        }
        if !compatibility.collations.isEmpty,
            group.events.contains(where: { event in
                !event.replicationFiltered
                    && (event.wireColumns ?? []).contains {
                        compatibility.targetID($0.collation) != $0.collation
                    }
            })
        {
            return .collationMapping
        }
        return nil
    }
}
