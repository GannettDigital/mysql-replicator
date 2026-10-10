import Foundation

/// Stable public identifiers; never infer eligibility by parsing message text.
public enum ApplyErrorCode: String, Codable, CaseIterable {
    case unsupportedDDL = "ddl.unsupported_statement"
    case unsupportedColumnType = "ddl.unsupported_column_type"
    case unsupportedAlter = "ddl.unsupported_alter"
    case unsupportedCollation = "ddl.unsupported_collation"
    case multipleStatements = "dml.multiple_statements"
    case multipleTables = "dml.multiple_tables"
    case duplicateKey = "mysql.1062"
    case targetSQL = "target.sql"
}

public struct SkipErrorPolicy: Decodable {
    public var codes: [ApplyErrorCode] = []
    public var recordSkippedTransactions = true
    public init() {}
    enum CodingKeys: String, CodingKey { case codes, recordSkippedTransactions }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        codes=try c.decodeIfPresent([ApplyErrorCode].self,forKey:.codes) ?? []
        recordSkippedTransactions=try c.decodeIfPresent(Bool.self,forKey:.recordSkippedTransactions) ?? true
    }
    func validate() throws {
        try require(Set(codes).count == codes.count && !codes.contains(.targetSQL),"skipErrors requires distinct, supported error codes; target.sql is not skippable")
    }
    enum Boundary { case beforeWrites, rolledBack }
    func match(_ error: Error, at boundary: Boundary) -> SkippedApplyError? {
        guard let error=error as? ApplyError,let code=error.code,codes.contains(code) else { return nil }
        switch boundary {
        case .beforeWrites:
            guard code != .duplicateKey && code != .targetSQL else { return nil }
        case .rolledBack:
            guard code == .duplicateKey else { return nil }
        }
        return .init(code:code,reason:error.message,mysqlErrorNumber:error.mysqlErrorNumber,
                     sqlState:error.sqlState,outcome:boundary == .beforeWrites ? "notIssued" : "rolledBack")
    }
}

struct SkippedApplyError: Codable {
    let code: ApplyErrorCode
    let reason: String
    let mysqlErrorNumber: Int?
    let sqlState: String?
    let outcome: String
}
