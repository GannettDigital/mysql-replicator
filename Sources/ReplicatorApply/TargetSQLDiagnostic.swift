import MySQLNIO

/// Retain the server response and SQL template. Do not expand bound values.
/// Server messages and literal SQL can contain data, as can the support bundle.
public struct TargetSQLDiagnostic: Codable, Equatable {
    let sql: String
    let mysqlErrorNumber: Int?
    let sqlState: String?
    let serverMessage: String

    static func applyError(_ error: MySQLError, sql: String) -> ApplyError {
        let number: Int?
        let state: String?
        let message: String
        let code: ApplyErrorCode?
        switch error {
        case .duplicateEntry(let text):
            (number, state, message, code) = (1062, "23000", text, .duplicateKey)
        case .invalidSyntax(let text):
            (number, state, message, code) = (1064, "42000", text, nil)
        case .server(let packet):
            number = Int(packet.errorCode.rawValue)
            state = packet.sqlState
            message = packet.errorMessage
            // Preserve the existing refusal classification for our MyISAM checks.
            let internalCheck =
                number == 1644
                && [
                    "target before-image mismatch or missing row", "unexpected target affected-row count",
                    "target after-image mismatch",
                ].contains(message)
            if internalCheck {
                return ApplyError(
                    message,
                    targetSQL: .init(
                        sql: sql, mysqlErrorNumber: number, sqlState: state, serverMessage: message))
            }
            code = number == 1062 ? .duplicateKey : .targetSQL
        default:
            return ApplyError("target connection/protocol failure; SQL outcome may be uncertain")
        }
        return ApplyError(
            "target SQL error \(number.map(String.init) ?? "unknown"), state \(state ?? "unknown"): \(message)",
            code: code, mysqlErrorNumber: number, sqlState: state,
            targetSQL: .init(sql: sql, mysqlErrorNumber: number, sqlState: state, serverMessage: message))
    }
}
