import Foundation

extension DDLStatement {
    var alterRenameDestination: TableName? {
        guard case .alter(_, let actions) = self else { return nil }
        // Native ALTER retains the last rename clause. It does not visit the
        // intermediate names as a RENAME TABLE list would.
        return actions.compactMap { action in
            if case .renameTable(let name) = action { return name }
            return nil
        }.last
    }
}

extension PreparedDDL {
    func applyingAlterRename() throws -> PreparedDDL {
        guard let destination = statement.alterRenameDestination else { return self }
        guard let before, let after else { throw ApplyError("ALTER RENAME requires before and after schemas") }
        let rename = TableRename(from: TableName(database: before.database, table: before.table), to: destination)
        var result = self
        var renamed = after.renamed(to: destination)
        renamed.savedRowIdentity = after.savedRowIdentity
        result.after = renamed
        // Column/FK/index changes have already been resolved against the old
        // table name. Rename the full resulting relationship component once.
        result.additional = additional.map { change in
            guard var peer = change.after else { return change }
            peer.foreignKeys = peer.foreignKeys.map { $0.renamed(rename) }
            return SchemaTransition(before: change.before, after: peer)
        }
        return result
    }
}

extension PreparedDDL {
    func validateNativeAlterRename(profile: ReplicationProfile) throws {
        guard NativeReplicationRules(profile: profile).unsafeFKRenameWithAddedColumn, let before,
            let destination = statement.alterRenameDestination, destination.identity != before.identity,
            case .alter(_, let actions) = statement,
            actions.contains(where: {
                if case .add = $0 { return true }
                return false
            })
        else { return }
        let renamedColumns = actions.compactMap { action -> String? in
            if case .modify(let old, let new, _) = action, !SQLIdentifier.equal(old, new.name) { return old }
            return nil
        }
        let hasFKRename = before.foreignKeys.contains { key in
            (key.parent == before.identity
                && renamedColumns.contains(where: { SQLIdentifier.contains(key.referencedColumns, $0) }))
        }
        try require(
            !hasFKRename,
            "target MySQL 8.4 native ALTER limitation: combining table rename, referenced parent-column rename and ADD COLUMN can fail or lose cascade behavior; issue ADD COLUMN as a separate source ALTER"
        )
    }
}
