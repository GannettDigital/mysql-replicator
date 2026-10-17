import ReplicatorCodec

/// An ENUM error value is a stored ordinal, not the declared empty-string label.
/// Native row apply copies it without SQL conversion. Our SQL connection needs
/// a scoped non-strict write followed by an exact result check.
enum EnumZeroWrite {
    static let strictMode = "STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION,NO_BACKSLASH_ESCAPES"
    static let writeMode = "NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION,NO_BACKSLASH_ESCAPES"

    static func required(table: ApplyTable, after: [DecodedValue]?) -> Bool {
        guard let after else { return false }
        return zip(table.columns,after).contains { $0.type.hasPrefix("enum(") && $1 == .unsigned(0) }
    }

    static func withMode<T>(required: Bool, setMode: (String) throws -> Void,
                            discardConnection: () -> Void, body: () throws -> T) throws -> T {
        guard required else { return try body() }
        try setMode(writeMode)
        let outcome: Result<T,Error>
        do { outcome = .success(try body()) }
        catch { outcome = .failure(error) }
        do { try setMode(strictMode) }
        catch {
            discardConnection()
            // Do not expose the original error as skippable when the session
            // can no longer enforce strict mode for the following statement.
            let previous: String
            switch outcome {
            case .success: previous = "write and result check completed"
            case .failure(let failure): previous = String(describing:failure)
            }
            throw ApplyError("cannot restore strict SQL mode after ENUM zero write: \(error); previous outcome: \(previous)")
        }
        return try outcome.get()
    }
}
