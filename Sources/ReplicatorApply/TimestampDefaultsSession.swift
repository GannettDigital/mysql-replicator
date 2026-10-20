/// Connection-local state. A new target connection must check its own default.
final class TimestampDefaultsSession {
    private var ready = false

    func prepare(read: () throws -> String?, enable: () throws -> Void) throws {
        guard !ready else { return }
        switch try read()?.uppercased() {
        case "1", "ON": break
        case "0", "OFF":
            do { try enable() } catch let error as ApplyError {
                throw ApplyError(
                    "DDL requires explicit_defaults_for_timestamp=ON in the target session; "
                        + "ask the DBA to enable the server default, then reconnect: \(error)",
                    code: error.code, mysqlErrorNumber: error.mysqlErrorNumber, sqlState: error.sqlState,
                    targetSQL: error.targetSQL)
            }
        default: throw ApplyError("cannot read target session explicit_defaults_for_timestamp")
        }
        ready = true
    }
}
