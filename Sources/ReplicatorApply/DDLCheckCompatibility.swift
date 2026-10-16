import Foundation
import MySQLSyntax

extension DDLParser {
    mutating func ignoredCheck() throws {
        switch nativeRules.checkConstraints {
        case .targetUnsupported:
            throw ApplyError("target MySQL 5.7 cannot preserve CHECK constraints from a source with CHECK support (MySQL 8.0.16 or later)",code:.unsupportedDDL)
        case .preserve:
            throw ApplyError("CHECK constraint schema tracking is not implemented for this source/target pair",code:.unsupportedDDL)
        case .discard: break
        }
        do {
            let clause=try SQLCheckClause.parsePrefix(tokens[index...])
            guard let range=clause.range else { throw ApplyError("CHECK compatibility requires source byte ranges") }
            edits.append(.init(range:range,replacement:""))
            index += clause.consumed
            ignoredCheckCount += 1
        } catch let error as SQLSyntaxError { throw ApplyError(error.message,code:.unsupportedDDL) }
    }

    /// Remove complete list items and their commas. Runs of adjacent removed
    /// items produce one edit. Kept SQL bytes, literals and comments stay intact.
    mutating func removeIgnoredItems(_ items:[(range:Range<Int>,ignored:Bool)]) {
        var i=0
        while i < items.count {
            if !items[i].ignored { i += 1;continue }
            let start=i
            while i < items.count && items[i].ignored { i += 1 }
            let range:Range<Int>
            if i < items.count { range=items[start].range.lowerBound..<items[i].range.lowerBound }
            else if start > 0 { range=items[start-1].range.upperBound..<items[i-1].range.upperBound }
            else { range=items[start].range.lowerBound..<items[i-1].range.upperBound }
            // Replace the smaller CHECK-only deletions with the whole item run.
            edits.removeAll { range.lowerBound <= $0.range.lowerBound && range.upperBound >= $0.range.upperBound }
            edits.append(.init(range:range,replacement:""))
        }
    }
    func itemRange(from start:Int) throws -> Range<Int> {
        guard start < index, let first=tokens[start].range, let last=tokens[index-1].range else { throw ApplyError("DDL compatibility requires source byte ranges") }
        return first.lowerBound..<last.upperBound
    }
}

extension DDLStatement {
    var ignoredChecksOnly: Bool {
        if case .alter(_,let actions)=self {
            return !actions.isEmpty && actions.allSatisfy { if case .ignoredCheck=$0 { return true };return false }
        }
        return false
    }
}
